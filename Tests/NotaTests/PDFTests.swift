import AppKit
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

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaPDFTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
