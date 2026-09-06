import AppKit
import Foundation
import WebKit
import XCTest
@testable import Nota

/// The third thing Nota opens rather than edits (SPEC Todo 3). A book is a tab
/// like any other — it is in the strip, ⌘W closes it, the session brings it
/// back — and like a PDF and a picture it is read: locked in reading, never
/// dirty, never cached and never written to.
///
/// Every fixture here is a real EPUB, zipped the way the specification insists
/// on: `mimetype` first, stored rather than deflated, holding
/// `application/epub+zip`. That order is the whole of what tells a book from
/// any other zip, so a fixture that faked it would be testing nothing.
final class EPUBTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    private var windows: [NSWindow] = []

    @MainActor
    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows = []
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    // MARK: - What counts as a book

    /// The bytes decide, not the name: the archive's first entry is a stored
    /// `mimetype` reading `application/epub+zip`, and nothing else is.
    func testARealBookIsKnownByItsFirstEntryWhateverItIsNamed() throws {
        let named = try makeEPUB3(named: "novel.epub")
        let unnamed = try makeEPUB3(named: "novel")

        XCTAssertEqual(FileSniff.classify(at: named), .epub)
        XCTAssertEqual(FileSniff.classify(at: unnamed), .epub,
                       "a book called nothing in particular is still a book")
        XCTAssertTrue(Note.isOpenable(named))
        XCTAssertTrue(Note.isOpenable(unnamed))
    }

    /// A zip is a zip. Nota opens books, not archives, and the entry at the
    /// front of the file is the only thing that separates the two.
    func testAPlainZipIsNotABook() throws {
        let directory = try makeTemporaryDirectory()
        let zip = try makePlainZip(named: "bundle.zip", in: directory)

        XCTAssertNotEqual(FileSniff.classify(at: zip), .epub)
        XCTAssertFalse(Note.isOpenable(zip), "an archive is not a tab")
    }

    func testAZipWhoseFirstEntryClaimsTheWrongMediaTypeIsNotABook() throws {
        let wrong = try makeEPUB3(named: "impostor.epub", mediaType: "application/zip")
        XCTAssertNotEqual(FileSniff.classify(at: wrong), .epub,
                          "the media type is read, not assumed from the entry's name")
    }

    /// The other direction of the same rule: a `.epub` whose bytes are text
    /// opens as text, the way a `.pdf` that is really a log does.
    func testAFileNamedEPUBWhoseBytesAreTextOpensAsText() throws {
        let directory = try makeTemporaryDirectory()
        let liar = directory.appendingPathComponent("notes.epub")
        try Data("# not a book at all".utf8).write(to: liar)

        XCTAssertEqual(FileSniff.classify(at: liar), .text)
        XCTAssertTrue(Note.isOpenable(liar))
    }

    /// A book that is not there to be read is still a book by name — the same
    /// fallback that keeps a missing `.pdf`'s tab a PDF tab.
    func testAMissingBookIsStillABookByName() throws {
        let directory = try makeTemporaryDirectory()
        let gone = directory.appendingPathComponent("gone.epub")
        XCTAssertEqual(FileSniff.classify(at: gone), .unreadable)
        XCTAssertEqual(Note.viewerKind(gone), .epub)
        XCTAssertTrue(Note.isEPUBFile(URL(fileURLWithPath: "/tmp/NOVEL.EPUB")))
        XCTAssertFalse(Note.isEPUBFile(URL(fileURLWithPath: "/tmp/notes.md")))
    }

    /// The strip's icon, and the same one in the ⇧⌘J switcher's rows.
    func testABookWearsTheBookIcon() {
        XCTAssertEqual(FileKindIcon.symbolName(forTitle: "novel.epub"), "filetype-epub")
        XCTAssertEqual(
            FileKindIcon.symbolName(for: URL(fileURLWithPath: "/tmp/novel.EPUB")), "filetype-epub",
            "and whatever case it is written in"
        )
    }

    // MARK: - Reading the book itself

    /// `META-INF/container.xml` names the package document, and the package's
    /// spine is the order the chapters are read in — not the order the
    /// manifest happens to list them.
    func testTheContainerNamesThePackageAndTheSpineIsTheReadingOrder() throws {
        let book = try XCTUnwrap(EPUBBook.open(try makeEPUB3(named: "novel.epub")))

        XCTAssertEqual(book.packageURL.lastPathComponent, "content.opf")
        XCTAssertEqual(book.title, "A Small Book")
        XCTAssertEqual(book.chapters.map { $0.url.lastPathComponent },
                       ["ch1.xhtml", "ch2.xhtml", "ch3.xhtml"])
        XCTAssertEqual(book.chapters.map(\.id), ["c1", "c2", "c3"])
        XCTAssertEqual(book.chapters.map(\.title),
                       ["The Beginning", "The Middle", "The End"],
                       "a chapter is called what the contents call it")
    }

    /// EPUB 3 keeps its contents in a `nav` document, nested as lists.
    func testAnEPUB3NavBecomesTheContents() throws {
        let book = try XCTUnwrap(EPUBBook.open(try makeEPUB3(named: "novel.epub")))

        XCTAssertEqual(book.contents.map(\.title),
                       ["The Beginning", "The Middle", "A Second Part", "The End"])
        XCTAssertEqual(book.contents.map(\.level), [1, 1, 2, 1],
                       "the nesting of the lists is the level")
        XCTAssertEqual(book.contents.map(\.chapterIndex), [0, 1, 1, 2])
        XCTAssertEqual(book.contents.map(\.fragment), [nil, nil, "part-two", nil])

        XCTAssertEqual(book.contentsEntries.map(\.title),
                       ["The Beginning", "The Middle", "A Second Part", "The End"])
        XCTAssertEqual(book.contentsEntries.map(\.line), [0, 1, 2, 3],
                       "an entry's line is its own place in the contents")
        let destination = try XCTUnwrap(book.destination(ofContentsLine: 2))
        XCTAssertEqual(destination.chapter, 1)
        XCTAssertEqual(destination.fragment, "part-two")
    }

    /// EPUB 2 has no nav document: its contents are an NCX hung off the
    /// spine's `toc` attribute, nested as `navPoint`s.
    func testAnEPUB2NCXBecomesTheContents() throws {
        let book = try XCTUnwrap(EPUBBook.open(try makeEPUB2(named: "old.epub")))

        XCTAssertEqual(book.chapters.map { $0.url.lastPathComponent },
                       ["ch1.xhtml", "ch2.xhtml"])
        XCTAssertEqual(book.contents.map(\.title), ["Opening", "Inside", "Closing"])
        XCTAssertEqual(book.contents.map(\.level), [1, 2, 1])
        XCTAssertEqual(book.contents.map(\.chapterIndex), [0, 0, 1])
        XCTAssertEqual(book.contents.map(\.fragment), [nil, "inside", nil])
        XCTAssertEqual(book.chapters.map(\.title), ["Opening", "Closing"])
    }

    /// A file that will not come apart is no book at all — not a crash, and
    /// not half a book either.
    func testACorruptBookIsNoBookAtAll() throws {
        XCTAssertNil(EPUBBook.open(try makeCorruptEPUB(named: "torn.epub")))
        XCTAssertNil(
            EPUBBook.open(try makeTemporaryDirectory().appendingPathComponent("nope.epub"))
        )
    }

    /// The folder a book is unpacked into belongs to the book and goes with
    /// it — a tab closed must not leave the temporary directory behind.
    func testTheUnpackedFolderGoesWhenTheBookDoes() throws {
        var book: EPUBBook? = EPUBBook.open(try makeEPUB3(named: "novel.epub"))
        let unpacked = try XCTUnwrap(book?.unpackedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unpacked.path))

        book = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: unpacked.path),
                       "the folder is the book's own")
    }

    // MARK: - Opening one

    @MainActor
    func testOpeningABookAddsAReadingTabShowingItsFirstChapter() throws {
        let controller = try makeController(store: try makeStore())
        controller.open(url: try makeEPUB3(named: "novel.epub"))

        XCTAssertEqual(controller.openNotes.last?.title, "novel.epub")
        XCTAssertEqual(controller.currentTabState.kind, .epub)
        XCTAssertEqual(controller.previewMode, .reading, "a book is the page and nothing else")
        XCTAssertTrue(controller.previewState.isVisible)
        XCTAssertTrue(controller.previewPanes.showsBook, "the book, not the render")
        XCTAssertFalse(controller.previewPanes.showsPDF)
        XCTAssertEqual(controller.previewPanes.epub.chapterCount, 3)
        XCTAssertEqual(controller.previewPanes.epub.chapterIndex, 0)
        XCTAssertEqual(controller.previewPanes.epub.chapterTitle, "The Beginning")
        XCTAssertFalse(controller.currentTabState.isDirty, "there is nothing to save")
    }

    @MainActor
    func testABookTabIsReadAndNeverWritten() throws {
        let controller = try makeController(store: try makeStore())
        let epub = try makeEPUB3(named: "novel.epub")
        let original = try Data(contentsOf: epub)
        controller.open(url: epub)

        XCTAssertFalse(controller.currentTabIsSavable, "⌘S and ⇧⌘S are greyed out")
        controller.saveCurrent(forcePanel: false)
        XCTAssertFalse(controller.vimSave(name: nil), ":w has nothing to write")
        XCTAssertEqual(try Data(contentsOf: epub), original, "the file is untouched")

        XCTAssertFalse(controller.currentTabState.isDirty)
        XCTAssertFalse(controller.canShowRenderedPreview,
                       "there is no Markdown render behind a book")
        let (editor, preview) = controller.modeControlOverlays
        XCTAssertTrue(editor.isHidden, "no control in the collapsed editor column")
        XCTAssertTrue(preview.isHidden, "and none over the book either")

        // And no other mode is on offer.
        controller.setPreviewMode(.off)
        XCTAssertEqual(controller.previewMode, .reading)
        controller.toggleMarkdownPreview()
        XCTAssertEqual(controller.previewMode, .reading)
    }

    @MainActor
    func testABookHasNoEncodingLineEndingOrWordCount() throws {
        let controller = try makeController(store: try makeStore())
        controller.open(url: try makeEPUB3(named: "novel.epub"))

        XCTAssertEqual(controller.footerRegions.counts.stringValue, "3 chapters")
        XCTAssertEqual(controller.footerRegions.cursor.stringValue, "Chapter 1 of 3")
        XCTAssertEqual(controller.footerRegions.encoding.stringValue, "")
        XCTAssertEqual(controller.footerRegions.lineEnding.stringValue, "")

        // And back to the editor's own counts the moment a text tab is in
        // front. Which spelling of them the footer picks is a question of the
        // room it has, and is `NotaTests`' to ask; all that matters here is
        // that the book has stopped answering for the middle of the bar.
        controller.newTab()
        try XCTUnwrap(controller.window).layoutIfNeeded()
        XCTAssertFalse(controller.footerRegions.counts.stringValue.contains("chapter"))
        XCTAssertEqual(controller.footerRegions.cursor.stringValue, "Ln 1, Col 1")
    }

    func testTheChapterCountsAreSpelledOutTheWayTheFooterSaysThem() {
        XCTAssertEqual(TextStats.chapterCounts(0), "0 chapters")
        XCTAssertEqual(TextStats.chapterCounts(1), "1 chapter")
        XCTAssertEqual(TextStats.chapterCounts(9), "9 chapters")
        XCTAssertEqual(TextStats.chapterPosition(current: 1, total: 9), "Chapter 1 of 9")
    }

    @MainActor
    func testSwitchingBetweenAMarkdownTabAndABookSwapsThePane() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeController(store: try makeStore())
        let markdown = directory.appendingPathComponent("notes.md")
        try "# Heading\n\nA paragraph.".write(to: markdown, atomically: true, encoding: .utf8)

        controller.open(url: markdown)
        controller.setPreviewMode(.reading)
        let markdownTab = controller.selectedTabIndex

        controller.open(url: try makeEPUB3(named: "novel.epub"))
        let bookTab = controller.selectedTabIndex
        XCTAssertTrue(controller.previewPanes.showsBook)

        controller.selectTab(at: markdownTab)
        XCTAssertFalse(controller.previewPanes.showsBook, "the render is back")
        XCTAssertTrue(controller.previewState.renderedText.contains("Heading"))

        controller.selectTab(at: bookTab)
        XCTAssertTrue(controller.previewPanes.showsBook)
    }

    // MARK: - Turning the chapters

    @MainActor
    func testTheChaptersWalkTheSpineAndStopAtBothEnds() throws {
        let controller = try makeController(store: try makeStore())
        controller.open(url: try makeEPUB3(named: "novel.epub"))
        let pane = controller.previewPanes.epub

        XCTAssertEqual(pane.chapterTitle, "The Beginning")
        XCTAssertEqual(controller.footerRegions.cursor.stringValue, "Chapter 1 of 3")

        pane.stepChapter(by: 1)
        XCTAssertEqual(pane.chapterIndex, 1)
        XCTAssertEqual(pane.chapterTitle, "The Middle")
        XCTAssertEqual(controller.footerRegions.cursor.stringValue, "Chapter 2 of 3")

        pane.stepChapter(by: 1)
        XCTAssertEqual(pane.chapterIndex, 2)

        pane.stepChapter(by: 1)
        XCTAssertEqual(pane.chapterIndex, 2, "the end of the book is the end")
        pane.stepChapter(by: -1)
        XCTAssertEqual(pane.chapterIndex, 1)
        pane.goToChapter(0)
        pane.stepChapter(by: -1)
        XCTAssertEqual(pane.chapterIndex, 0, "and so is the start")
    }

    /// Nothing floats over the chapter but the tools the reader opened. The
    /// bar that used to turn chapters is gone: a control with no way to close
    /// it has no business standing on the page, and the contents are in the
    /// sidebar now.
    @MainActor
    func testTheColumnHasNoFloatingChapterControl() throws {
        let controller = try makeController(store: try makeStore())
        controller.open(url: try makeEPUB3(named: "novel.epub"))
        let pane = controller.previewPanes.epub

        let floating = descendants(of: pane, ofType: PillView.self)
        let unexpected = floating.filter { !($0 is FindBarView) && !($0 is ReplaceBarView) }
        XCTAssertTrue(unexpected.isEmpty,
                      "the column still floats \(unexpected.map { type(of: $0) })")
    }

    /// `@` over a book lists nothing at all: a book's contents live in the
    /// sidebar, where they can stay on screen while the chapter is read.
    @MainActor
    func testTheSwitcherListsNoHeadingsForABook() throws {
        let controller = try makeKeyController()
        controller.open(url: try makeEPUB3(named: "novel.epub"))

        controller.showTabPicker()
        let picker = controller.tabPickerPanel
        defer { picker.hide() }

        picker.query = "@"
        XCTAssertTrue(picker.isShowingHeadings, "`@` still switches the list over")
        XCTAssertEqual(picker.visibleRowTexts, [], "and the list is empty")
    }

    /// A text tab's `@` list is still its own headings — a book's contents
    /// belong to the book and to nothing else.
    @MainActor
    func testATextTabsAtListIsUnchanged() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeKeyController()
        let markdown = directory.appendingPathComponent("notes.md")
        try "# Alpha\n\n## Beta\n".write(to: markdown, atomically: true, encoding: .utf8)
        controller.open(url: try makeEPUB3(named: "novel.epub"))
        controller.open(url: markdown)

        controller.showTabPicker()
        let picker = controller.tabPickerPanel
        defer { picker.hide() }
        picker.query = "@"
        XCTAssertEqual(picker.visibleRowTexts, ["Alpha", "Beta"])
    }

    // MARK: - The contents in the sidebar

    /// A book tab brings the column up on its own — the way a note with a
    /// picture in it does — and what stands in it is the book's own table of
    /// contents, nesting and all.
    @MainActor
    func testABookInFrontListsItsContentsInTheSidebar() throws {
        let controller = try makeKeyController()
        controller.open(url: exampleURL("Book.epub"))

        XCTAssertTrue(controller.isImageSidebarVisible, "the column came up with the book")
        XCTAssertTrue(controller.sidebarShowsContents)
        XCTAssertEqual(controller.contentsSidebarView.rowTitles, [
            "1. A Book in a Tab",
            "1.1 Turning pages",
            "1.2 Finding things",
            "2. Text and Pictures",
            "2.1 A short table",
            "3. The Last Chapter",
            "3.1 Afterword",
        ])
        XCTAssertEqual(controller.contentsSidebarView.rowIndents, [0, 12, 12, 0, 12, 0, 12],
                       "a section sits one step in from its chapter")
        XCTAssertEqual(controller.contentsSidebarView.selectedRowTitle, "1. A Book in a Tab",
                       "the chapter on screen is the line that is rung")
        XCTAssertEqual(controller.contentsSidebarView.headerTitle, "Contents",
                       "the one word saying what the column is listing")
        XCTAssertEqual(controller.contentsSidebarView.headerCount, 3,
                       "the badge after the title counts the chapters, not the sections under them")
        XCTAssertTrue(controller.pageListSidebarView.isHidden,
                      "a book is read by its chapters; it has no pages to lay out")
        XCTAssertEqual(controller.sidebarListTitle, "Table of Contents",
                       "and that is the longer name the View item carries")
    }

    /// The Traditional Chinese example: a name in Han characters on disk, a
    /// title and contents in them too. The contents parser folds runs of
    /// whitespace to one space, and an ideographic space (U+3000) is
    /// whitespace to it — so the full-width gap the book writes between
    /// "第一章" and its name comes back as an ordinary space.
    @MainActor
    func testTheChineseBookOpensWithItsContentsIntact() throws {
        let controller = try makeReadingController(url: exampleURL("燈籠.epub"))
        XCTAssertEqual(controller.previewPanes.epub.chapterCount, 3)
        XCTAssertEqual(controller.previewPanes.epub.chapterTitle, "第一章 燈籠")
        XCTAssertEqual(controller.contentsSidebarView.rowTitles, [
            "第一章 燈籠", "一、翻頁", "二、找字",
            "第二章 文字與圖表", "一、一張小表",
            "第三章 最後一章", "一、後記",
        ])
        XCTAssertEqual(controller.openNotes.last?.title, "燈籠.epub")
    }

    /// Clicking a line turns to the chapter it names, and the line rung goes
    /// with it.
    @MainActor
    func testClickingALineOfTheContentsTurnsToThatChapter() throws {
        let controller = try makeKeyController()
        controller.open(url: exampleURL("Book.epub"))
        let sidebar = controller.contentsSidebarView
        let row = try XCTUnwrap(sidebar.rowTitles.firstIndex(of: "2. Text and Pictures"))

        sidebar.chooseRow(row)

        XCTAssertEqual(controller.previewPanes.epub.chapterIndex, 1)
        XCTAssertEqual(controller.currentTabState.selection, 1,
                       "and that is where the tab is left")
        XCTAssertEqual(sidebar.selectedRowTitle, "2. Text and Pictures")
    }

    /// The keys a book is turned by are the page's own script, and the line
    /// rung follows them: `→` at the end of chapter one lands on chapter two,
    /// and the sidebar says so.
    @MainActor
    func testTurningAChapterWithTheKeyScriptMovesTheRungLine() throws {
        let controller = try makeReadingController(url: exampleURL("Book.epub"))
        let pane = controller.previewPanes.epub
        XCTAssertEqual(controller.contentsSidebarView.selectedRowTitle, "1. A Book in a Tab")

        let turned = expectation(description: "the next chapter loaded")
        turned.assertForOverFulfill = false
        pane.chapterPage.onLoadFinished = { turned.fulfill() }
        try evaluate(
            """
            document.dispatchEvent(
                new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true })
            );
            """,
            in: pane
        )
        wait(for: [turned], timeout: 10)
        pane.chapterPage.onLoadFinished = nil

        XCTAssertEqual(pane.chapterIndex, 1)
        XCTAssertEqual(controller.contentsSidebarView.selectedRowTitle, "2. Text and Pictures")
    }

    /// The column belongs to the tab in front: a book's contents while a book
    /// is being read, a note's pictures the moment one is.
    @MainActor
    func testSwitchingToATextTabSwapsTheContentsBackForTheGallery() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeKeyController()
        let markdown = directory.appendingPathComponent("notes.md")
        try "Just words.".write(to: markdown, atomically: true, encoding: .utf8)

        controller.open(url: markdown)
        let textTab = controller.selectedTabIndex
        controller.open(url: exampleURL("Book.epub"))
        let bookTab = controller.selectedTabIndex

        XCTAssertTrue(controller.sidebarShowsContents)
        XCTAssertFalse(controller.contentsSidebarView.isHidden)
        XCTAssertTrue(controller.quickLookSidebar.isHidden)

        controller.selectTab(at: textTab)
        XCTAssertFalse(controller.sidebarShowsContents)
        XCTAssertFalse(controller.isImageSidebarVisible,
                       "a note with no pictures has nothing to show")

        // Pinned open, the same column is the gallery again.
        controller.toggleImageSidebar()
        XCTAssertTrue(controller.isImageSidebarVisible)
        XCTAssertFalse(controller.quickLookSidebar.isHidden)
        XCTAssertTrue(controller.contentsSidebarView.isHidden)

        controller.selectTab(at: bookTab)
        XCTAssertTrue(controller.sidebarShowsContents)
        XCTAssertFalse(controller.contentsSidebarView.isHidden)
        XCTAssertTrue(controller.quickLookSidebar.isHidden)
    }

    // MARK: - The chapter is a page

    /// The chapter is drawn by the same web view a `.html` tab is, with the
    /// book's own stylesheet resolved out of the unpacked folder — which is
    /// the whole reason the archive is unpacked at all.
    @MainActor
    func testTheChapterIsDrawnWithTheBooksOwnStylesheet() throws {
        let controller = try makeReadingController(named: "novel.epub")
        let pane = controller.previewPanes.epub
        // Light: in dark the reader theme takes the body colour over (its own
        // test below), and the test process follows the Mac's setting.
        try XCTUnwrap(controller.window).appearance = NSAppearance(named: .aqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(try string("document.title", in: pane), "The Beginning")
        XCTAssertEqual(try string("getComputedStyle(document.body).color", in: pane),
                       "rgb(1, 2, 3)",
                       "the book's own style.css, out of the folder it was unpacked into")

        try turn(to: 1, in: pane)
        XCTAssertEqual(try string("document.title", in: pane), "The Middle")
        XCTAssertEqual(try string("getComputedStyle(document.body).color", in: pane),
                       "rgb(1, 2, 3)", "and it is still the book's style a chapter later")
    }

    /// ⌘F over a book is the page's own find session, in the same pill every
    /// other column keeps one in.
    @MainActor
    func testCommandFOverABookIsThePagesFindSession() throws {
        let controller = try makeReadingController(named: "novel.epub")
        let pane = controller.previewPanes.epub
        let bar = try XCTUnwrap(descendant(of: pane, ofType: FindBarView.self))
        XCTAssertEqual(bar.field.placeholderString, "Find in page")
        XCTAssertFalse(bar.isShown)

        let page = try XCTUnwrap(pane.chapterPage.webView)
        page.performTextFinderAction(finderItem(.showFindInterface))

        XCTAssertTrue(bar.isShown)
        XCTAssertTrue(pane.isFindBarVisible)
        XCTAssertEqual(controller.previewMode, .reading)
    }

    // MARK: - ⇧⌘F over the book

    /// A book's words come out of its chapters with the markup left behind
    /// (SPEC Done 37): block elements keep their lines apart, so a hit's
    /// snippet is the paragraph it sits in, and a stylesheet is not words.
    func testAChaptersWordsAreItsTextWithTheMarkupLeftBehind() throws {
        let book = try XCTUnwrap(EPUBBook.open(try makeEPUB3(named: "novel.epub")))
        let second = book.words(ofChapter: 1)
        let lines = second.components(separatedBy: "\n")

        XCTAssertEqual(Array(lines.prefix(4)),
                       ["The Middle", "A Second Part", "Line 1", "Line 2"],
                       "a heading and a paragraph are each a line of their own")
        XCTAssertFalse(second.contains("<"), "no markup came through")
        XCTAssertFalse(second.contains("style.css"), "and no stylesheet either")
        XCTAssertFalse(book.words(ofChapter: 0).contains("A Second Part"),
                       "a chapter's words are its own")
        XCTAssertEqual(book.words(ofChapter: 9), "", "a chapter that is not there has none")
    }

    /// A book is part of the search across tabs: a hit in one of its chapters
    /// is listed like any other, and choosing it turns to that chapter and
    /// puts the query to it.
    @MainActor
    func testSearchAllTabsFindsAndRevealsAHitInAChapter() throws {
        let controller = try makeKeyController()
        controller.open(url: try makeEPUB3(named: "novel.epub"))
        let pane = controller.previewPanes.epub
        XCTAssertEqual(pane.chapterIndex, 0)

        let picker = controller.tabPickerPanel
        controller.beginSearchAllNotes()
        picker.query = "Second"

        XCTAssertEqual(picker.visibleRowTexts, ["A Second Part"],
                       "the line the hit sits on, not the whole chapter")
        XCTAssertEqual(picker.visibleSearchMatches.map(\.tabTitle), ["novel.epub"])
        let match = try XCTUnwrap(picker.visibleSearchMatches.first)
        guard case .book(let chapter, let range) = match.location else {
            return XCTFail("a book's hit is located by its chapter")
        }
        XCTAssertEqual(chapter, 1)
        XCTAssertEqual(range.length, 6)

        send(#selector(NSResponder.insertNewline(_:)), to: picker)

        XCTAssertFalse(picker.isVisible, "choosing closes the panel")
        XCTAssertEqual(pane.chapterIndex, 1, "the chapter it is written in came up")
        XCTAssertEqual(pane.chapterTitle, "The Middle")
        XCTAssertEqual(pane.chapterPage.findQuery, "Second",
                       "and the chapter's own find took the query")
        XCTAssertTrue(pane.isFindBarVisible, "with the pill up on it")
        XCTAssertEqual(NSPasteboard(name: .find).string(forType: .string), "Second")
    }

    /// The key the picker's field would hand its delegate — the tests have no
    /// window server to press one with.
    @MainActor
    private func send(_ command: Selector, to picker: TabPickerPanel) {
        _ = picker.control(NSTextField(), textView: NSTextView(), doCommandBy: command)
    }

    // MARK: - The session

    @MainActor
    func testABookTabComesBackOnTheChapterItWasLeftOn() throws {
        let store = try makeStore()
        let epub = try makeEPUB3(named: "novel.epub")

        let opened = try makeController(store: store)
        opened.open(url: epub)
        opened.previewPanes.epub.goToChapter(1)
        opened.flushAll()

        let state = try XCTUnwrap(store.load())
        let tab = try XCTUnwrap(state.tabs.first { $0.path == epub.path })
        XCTAssertEqual(tab.previewMode, .reading)
        XCTAssertNil(tab.format, "a book has no encoding or line endings")
        XCTAssertFalse(tab.isDirty)
        XCTAssertEqual(tab.selection, 1, "the chapter is where the tab was left")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.cacheURL(for: tab.id).path),
            "nothing about a book belongs in the cache"
        )

        let relaunched = try makeController(store: SessionStore(directory: store.directory))
        relaunched.selectTab(at: try tabIndex(of: epub, in: relaunched))
        XCTAssertEqual(relaunched.currentTabState.kind, .epub)
        XCTAssertFalse(relaunched.currentTabState.isDirty)
        XCTAssertEqual(relaunched.previewMode, .reading)
        XCTAssertEqual(relaunched.previewPanes.epub.chapterCount, 3, "the file is read again")
        XCTAssertEqual(relaunched.previewPanes.epub.chapterIndex, 1)
        XCTAssertEqual(relaunched.previewPanes.epub.chapterTitle, "The Middle")
    }

    /// The chapter alone would come back to the top of a chapter half read,
    /// so how far down it goes into the session beside it.
    @MainActor
    func testHowFarDownAChapterIsRememberedAsWell() throws {
        let store = try makeStore()
        let epub = try makeEPUB3(named: "novel.epub")

        let note = Note(fileURL: epub, untitledName: nil, text: "",
                        attributes: [:], assets: nil, kind: .epub)
        note.selectionLocation = 2
        note.scrollFraction = 0.4
        let tab = note.sessionTab()
        XCTAssertEqual(tab.selection, 2)
        XCTAssertEqual(try XCTUnwrap(tab.scroll), 0.4, accuracy: 0.0001)

        // Through the file itself, since the session is JSON on disk.
        let id = tab.id
        store.save(SessionState(tabs: [tab], selectedTabID: id, fontSize: 13))
        let written = try XCTUnwrap(store.load()?.tabs.first)
        XCTAssertEqual(try XCTUnwrap(written.scroll), 0.4, accuracy: 0.0001)

        let relaunched = try makeController(store: SessionStore(directory: store.directory))
        relaunched.selectTab(at: try tabIndex(of: epub, in: relaunched))
        XCTAssertEqual(relaunched.currentTabState.kind, .epub)
        XCTAssertEqual(relaunched.currentTabState.selection, 2)
        XCTAssertEqual(relaunched.currentTabScroll, 0.4, accuracy: 0.0001)
    }

    /// A session written before books opened at all has no `scroll` key, and
    /// still reads back.
    func testASessionWithoutAScrollKeyStillDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","path":"/tmp/novel.epub","isDirty":false,
         "selection":3,"previewMode":"reading"}
        """
        let tab = try JSONDecoder().decode(SessionTab.self, from: Data(json.utf8))
        XCTAssertEqual(tab.selection, 3)
        XCTAssertNil(tab.scroll)
    }

    /// The whole loop with a real page in it: the reader scrolls, the page
    /// reports where it got to, and that share of the chapter is what the
    /// session file holds.
    @MainActor
    func testWhereTheReaderScrolledToReachesTheSessionFile() throws {
        let store = try makeStore()
        let controller = try makeReadingController(named: "novel.epub", store: store)
        let pane = controller.previewPanes.epub
        try turn(to: 2, in: pane)

        try evaluate("window.scrollTo(0, 1200);", in: pane)
        try waitForScrollReport(in: pane)

        let reported = try XCTUnwrap(pane.rememberedScroll)
        XCTAssertGreaterThan(reported, 0)
        controller.flushAll()

        let tab = try XCTUnwrap(store.load()?.tabs.first { $0.path?.hasSuffix("novel.epub") == true })
        XCTAssertEqual(tab.selection, 2)
        XCTAssertEqual(try XCTUnwrap(tab.scroll), reported, accuracy: 0.0001)
    }

    // MARK: - When there is no book to read

    @MainActor
    func testARestoredBookWhoseFileHasGoneKeepsItsTabAndSaysSo() throws {
        let store = try makeStore()
        let epub = try makeEPUB3(named: "novel.epub")

        let opened = try makeController(store: store)
        opened.open(url: epub)
        opened.flushAll()

        try FileManager.default.removeItem(at: epub)

        let relaunched = try makeController(store: SessionStore(directory: store.directory))
        relaunched.selectTab(at: try tabIndex(of: epub, in: relaunched))
        XCTAssertEqual(relaunched.currentTabState.kind, .epub, "the tab is still there")
        XCTAssertFalse(relaunched.currentTabState.isDirty,
                       "a file that has gone is not an unsaved edit")
        XCTAssertTrue(relaunched.previewPanes.showsBook)
        XCTAssertEqual(relaunched.previewPanes.epub.chapterCount, 0)
        XCTAssertEqual(relaunched.previewPanes.epub.missingMessage,
                       "Couldn’t open “novel.epub”.")
    }

    /// A book that will not come apart is the same state a missing one is —
    /// never a crash, and never a text tab of gibberish.
    @MainActor
    func testACorruptBookOpensInTheMissingState() throws {
        let controller = try makeController(store: try makeStore())
        controller.open(url: try makeCorruptEPUB(named: "torn.epub"))

        XCTAssertEqual(controller.currentTabState.kind, .epub,
                       "the bytes said book, so it is a book tab")
        XCTAssertTrue(controller.previewPanes.showsBook)
        XCTAssertEqual(controller.previewPanes.epub.chapterCount, 0)
        XCTAssertEqual(controller.previewPanes.epub.missingMessage,
                       "Couldn’t open “torn.epub”.")
        XCTAssertFalse(controller.currentTabState.isDirty)
        XCTAssertFalse(controller.currentTabIsSavable)
    }

    // MARK: - Dark mode

    /// A book's stylesheet is written for paper: `color: rgb(1, 2, 3)` on the
    /// body is "the text", and on Nota's dark ground it would be near-black
    /// type on near-black. In dark mode the chapter is read in the label
    /// colour instead; in light mode the author's colour stands.
    @MainActor
    func testAChapterIsReadInTheLabelColourWhenTheMacIsDark() throws {
        let controller = try makeReadingController(named: "novel.epub")
        let window = try XCTUnwrap(controller.window)
        let pane = controller.previewPanes.epub

        window.appearance = NSAppearance(named: .aqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(
            try evaluate("getComputedStyle(document.body).color", in: pane) as? String,
            "rgb(1, 2, 3)", "light: the book's own colour"
        )

        window.appearance = NSAppearance(named: .darkAqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(
            try evaluate("window.matchMedia('(prefers-color-scheme: dark)').matches", in: pane) as? Bool,
            true, "the page follows the window's appearance"
        )
        XCTAssertEqual(
            try evaluate("getComputedStyle(document.body).color", in: pane) as? String,
            "rgba(255, 255, 255, 0.85)", "dark: Nota's label colour"
        )
        XCTAssertEqual(
            try evaluate("!!document.querySelector('style[data-nota=reader-theme]')", in: pane) as? Bool,
            true, "the reader theme went in with the chapter"
        )
    }

    /// The editor/preview split's own divider used to be drawn down the
    /// window's leading edge in reading — a 1pt dark line right beside the
    /// sidebar's divider, so the seam read as two lines. Outside split the
    /// divider is not drawn at all.
    @MainActor
    func testTheDocumentSplitDrawsNoDividerWhileTheEditorIsClosed() throws {
        let controller = try makeReadingController(named: "novel.epub")
        let window = try XCTUnwrap(controller.window)
        window.appearance = NSAppearance(named: .darkAqua)
        let content = try XCTUnwrap(window.contentView)
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let split = try XCTUnwrap(
            content.descendants.compactMap { $0 as? DocumentSplitView }.first,
            "the document split draws through its own view"
        )
        XCTAssertTrue(split.hidesDivider(), "reading: the editor column is closed")

        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        // The divider stands at the split's leading edge; a point inside the
        // column is the ground it should match.
        let edge = split.convert(NSPoint(x: split.bounds.minX, y: split.bounds.midY), to: content)
        let inside = split.convert(NSPoint(x: split.bounds.minX + 20, y: split.bounds.midY), to: content)
        let scale = CGFloat(rep.pixelsWide) / content.bounds.width
        func colour(at point: NSPoint) throws -> NSColor {
            try XCTUnwrap(rep.colorAt(
                x: Int(point.x * scale), y: Int((content.bounds.height - point.y) * scale)
            ))
        }
        XCTAssertEqual(
            try colour(at: edge).redComponent, try colour(at: inside).redComponent,
            accuracy: 0.02, "no line down the window's edge"
        )
    }

    // MARK: - Fixtures

    /// A whole EPUB 3: a nav document for its contents, three chapters in the
    /// spine, and a stylesheet of its own that the pane has to resolve out of
    /// the unpacked folder.
    private func makeEPUB3(
        named name: String, mediaType: String = "application/epub+zip"
    ) throws -> URL {
        try makeEPUB(named: name, mediaType: mediaType, files: [
            "META-INF/container.xml": Self.container,
            "OEBPS/content.opf": Self.package3,
            "OEBPS/nav.xhtml": Self.nav,
            "OEBPS/style.css": "body { color: rgb(1, 2, 3); }",
            "OEBPS/ch1.xhtml": Self.chapter(titled: "The Beginning", body: Self.filler),
            "OEBPS/ch2.xhtml": Self.chapter(
                titled: "The Middle",
                body: "<h2 id=\"part-two\">A Second Part</h2>" + Self.filler
            ),
            "OEBPS/ch3.xhtml": Self.chapter(titled: "The End", body: Self.filler),
        ])
    }

    /// The same book as an EPUB 2: no nav document, an NCX off the spine's
    /// `toc` attribute instead.
    private func makeEPUB2(named name: String) throws -> URL {
        try makeEPUB(named: name, mediaType: "application/epub+zip", files: [
            "META-INF/container.xml": Self.container,
            "OEBPS/content.opf": Self.package2,
            "OEBPS/toc.ncx": Self.ncx,
            "OEBPS/style.css": "body { color: rgb(4, 5, 6); }",
            "OEBPS/ch1.xhtml": Self.chapter(
                titled: "Opening", body: "<h2 id=\"inside\">Inside</h2>" + Self.filler
            ),
            "OEBPS/ch2.xhtml": Self.chapter(titled: "Closing", body: Self.filler),
        ])
    }

    /// A real archive, zipped the way the specification insists on: `mimetype`
    /// written first and stored rather than deflated, everything else after
    /// it. `zip` is used rather than `ditto -c`, which gives no promise about
    /// the order entries land in — and the order is the whole point.
    private func makeEPUB(
        named name: String, mediaType: String, files: [String: String]
    ) throws -> URL {
        let staging = try makeTemporaryDirectory()
        try Data(mediaType.utf8).write(to: staging.appendingPathComponent("mimetype"))
        for (path, contents) in files {
            let file = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: file)
        }

        // Always built with an extension: `zip` appends `.zip` to an output
        // path that has none, and half the point of these fixtures is a book
        // that is not called one.
        let directory = try makeTemporaryDirectory()
        let built = directory.appendingPathComponent("built.epub")
        try run("/usr/bin/zip", ["-X", "-0", built.path, "mimetype"], in: staging)
        let rest = Set(files.keys.map { String($0.split(separator: "/")[0]) }).sorted()
        try run("/usr/bin/zip", ["-X", "-r", built.path] + rest, in: staging)
        let epub = directory.appendingPathComponent(name)
        if epub != built { try FileManager.default.moveItem(at: built, to: epub) }

        // The fixture is only a fixture if the sniff would call it a book.
        let head = try XCTUnwrap(TextFile.head(of: epub))
        XCTAssertTrue([UInt8](head.prefix(4)) == [0x50, 0x4B, 0x03, 0x04])
        return epub
    }

    /// A book whose front is intact — so the sniff still calls it one — and
    /// whose archive is torn off part way through, so nothing can be unpacked.
    private func makeCorruptEPUB(named name: String) throws -> URL {
        let whole = try makeEPUB3(named: "whole.epub")
        let torn = try makeTemporaryDirectory().appendingPathComponent(name)
        try Data(contentsOf: whole).prefix(120).write(to: torn)
        XCTAssertEqual(FileSniff.classify(at: torn), .epub,
                       "the first entry is still there to be read")
        return torn
    }

    /// A zip that is only a zip — no `mimetype` entry at the front of it.
    private func makePlainZip(named name: String, in directory: URL) throws -> URL {
        let staging = try makeTemporaryDirectory()
        try Data("just some notes".utf8).write(to: staging.appendingPathComponent("notes.txt"))
        let zip = directory.appendingPathComponent(name)
        try run("/usr/bin/zip", ["-X", "-r", zip.path, "notes.txt"], in: staging)
        return zip
    }

    private func run(_ tool: String, _ arguments: [String], in directory: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        task.currentDirectoryURL = directory
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, "\(tool) \(arguments.joined(separator: " "))")
    }

    private static let container = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf"
                  media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    /// The manifest deliberately lists the chapters out of order, so a test
    /// that passes can only be reading the spine.
    private static let package3 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>A Small Book</dc:title>
        <dc:identifier id="pub-id">urn:uuid:nota-test</dc:identifier>
        <dc:language>en</dc:language>
      </metadata>
      <manifest>
        <item id="c3" href="ch3.xhtml" media-type="application/xhtml+xml"/>
        <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="css" href="style.css" media-type="text/css"/>
        <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
      </manifest>
      <spine>
        <itemref idref="c1"/>
        <itemref idref="c2"/>
        <itemref idref="c3"/>
      </spine>
    </package>
    """

    private static let package2 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="pub-id">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>An Older Book</dc:title>
        <dc:identifier id="pub-id">urn:uuid:nota-test-2</dc:identifier>
      </metadata>
      <manifest>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        <item id="css" href="style.css" media-type="text/css"/>
        <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
        <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
      </manifest>
      <spine toc="ncx">
        <itemref idref="c1"/>
        <itemref idref="c2"/>
      </spine>
    </package>
    """

    private static let nav = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
      <head><title>Contents</title></head>
      <body>
        <nav epub:type="toc">
          <ol>
            <li><a href="ch1.xhtml">The Beginning</a></li>
            <li><a href="ch2.xhtml">The Middle</a>
              <ol><li><a href="ch2.xhtml#part-two">A Second Part</a></li></ol>
            </li>
            <li><a href="ch3.xhtml">The End</a></li>
          </ol>
        </nav>
      </body>
    </html>
    """

    private static let ncx = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
      <head><meta name="dtb:uid" content="urn:uuid:nota-test-2"/></head>
      <docTitle><text>An Older Book</text></docTitle>
      <navMap>
        <navPoint id="n1" playOrder="1">
          <navLabel><text>Opening</text></navLabel>
          <content src="ch1.xhtml"/>
          <navPoint id="n1a" playOrder="2">
            <navLabel><text>Inside</text></navLabel>
            <content src="ch1.xhtml#inside"/>
          </navPoint>
        </navPoint>
        <navPoint id="n2" playOrder="3">
          <navLabel><text>Closing</text></navLabel>
          <content src="ch2.xhtml"/>
        </navPoint>
      </navMap>
    </ncx>
    """

    /// Tall enough to be scrolled a long way down, so a remembered place in a
    /// chapter is a real one.
    private static let filler = (1 ... 120)
        .map { "<p style=\"height: 40px\">Line \($0)</p>" }
        .joined()

    private static func chapter(titled title: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head>
            <title>\(title)</title>
            <link rel="stylesheet" type="text/css" href="style.css"/>
          </head>
          <body><h1>\(title)</h1>\(body)</body>
        </html>
        """
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

    @MainActor
    private func makeKeyController() throws -> MainWindowController {
        let controller = try makeController(store: try makeStore())
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()
        windows.append(window)
        window.layoutIfNeeded()
        return controller
    }

    /// A controller whose one book tab has its first chapter actually landed.
    /// A load is asynchronous, so it is waited on rather than assumed.
    @MainActor
    private func makeReadingController(
        named name: String, store: SessionStore? = nil
    ) throws -> MainWindowController {
        try makeReadingController(url: try makeEPUB3(named: name), store: store)
    }

    /// The same, for a book that already exists on disk — the checked-in
    /// example rather than a fixture built for the test.
    @MainActor
    private func makeReadingController(
        url: URL, store: SessionStore? = nil
    ) throws -> MainWindowController {
        let controller = try makeController(store: store ?? (try makeStore()))
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()
        windows.append(window)

        let loaded = expectation(description: "the chapter loaded")
        loaded.assertForOverFulfill = false
        controller.previewPanes.epub.chapterPage.onLoadFinished = { loaded.fulfill() }
        controller.open(url: url)
        window.layoutIfNeeded()
        wait(for: [loaded], timeout: 10)
        controller.previewPanes.epub.chapterPage.onLoadFinished = nil
        return controller
    }

    /// A file in the folder of examples checked in beside the app — a real
    /// book a reader might open, rather than one zipped up for the test.
    private func exampleURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/\(name)")
            .standardizedFileURL
    }

    /// Turns to a chapter and waits for its page to arrive.
    @MainActor
    private func turn(to index: Int, in pane: EPUBPreviewView) throws {
        let loaded = expectation(description: "chapter \(index) loaded")
        loaded.assertForOverFulfill = false
        pane.chapterPage.onLoadFinished = { loaded.fulfill() }
        pane.goToChapter(index)
        wait(for: [loaded], timeout: 10)
        pane.chapterPage.onLoadFinished = nil
        XCTAssertEqual(pane.chapterIndex, index)
    }

    @MainActor
    @discardableResult
    private func evaluate(_ javaScript: String, in pane: EPUBPreviewView) throws -> Any? {
        let answered = expectation(description: "the chapter answered")
        var value: Any?
        try XCTUnwrap(pane.chapterPage.webView).evaluateJavaScript(
            javaScript, in: nil, in: .defaultClient
        ) { outcome in
            if case .success(let result) = outcome { value = result }
            answered.fulfill()
        }
        wait(for: [answered], timeout: 10)
        return value
    }

    @MainActor
    private func string(_ javaScript: String, in pane: EPUBPreviewView) throws -> String {
        try XCTUnwrap(evaluate(javaScript, in: pane) as? String)
    }

    /// The page reports its scroll on its own; nothing else says when the
    /// report has landed.
    @MainActor
    private func waitForScrollReport(in pane: EPUBPreviewView) throws {
        let reported = expectation(description: "the chapter reported its scroll")
        reported.assertForOverFulfill = false
        let poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if (pane.rememberedScroll ?? 0) > 0 { reported.fulfill() }
        }
        wait(for: [reported], timeout: 10)
        poll.invalidate()
    }

    private func makeStore() throws -> SessionStore {
        SessionStore(directory: try makeTemporaryDirectory())
    }

    @MainActor
    private func tabIndex(of url: URL, in controller: MainWindowController) throws -> Int {
        try XCTUnwrap(
            controller.openNotes.firstIndex {
                $0.fileURL?.standardizedFileURL == url.standardizedFileURL
            },
            "\(url.lastPathComponent) is not open"
        )
    }

    private func finderItem(_ action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem()
        item.action = #selector(NSTextView.performTextFinderAction(_:))
        item.tag = action.rawValue
        return item
    }

    private func descendant<T: NSView>(of view: NSView, ofType type: T.Type) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = descendant(of: subview, ofType: type) { return match }
        }
        return nil
    }

    /// Every one of them, not the first — what a test asking "and nothing
    /// else" needs.
    private func descendants<T: NSView>(of view: NSView, ofType type: T.Type) -> [T] {
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for subview in view.subviews {
            found.append(contentsOf: descendants(of: subview, ofType: type))
        }
        return found
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaEPUBTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}

extension NSView {
    /// Every view under this one, depth first.
    var descendants: [NSView] { subviews.flatMap { [$0] + $0.descendants } }
}
