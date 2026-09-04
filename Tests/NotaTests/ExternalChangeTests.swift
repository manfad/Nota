import AppKit
import PDFKit
import XCTest
@testable import Nota

/// SPEC Todo 1: a named tab watches its file. A clean tab reloads silently, a
/// dirty one is marked and offered Reload / Keep mine, and Nota's own ⌘S is
/// never mistaken for somebody else's write.
///
/// Nothing here sleeps. The dispatch source fires when the file system says
/// so, on a queue of its own, so every test waits on an expectation the
/// controller fulfils once it has dealt with the change.
final class ExternalChangeTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - The watch itself

    func testTheWatchHearsAPlainWriteToTheFile() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("notes.txt")
        try Data("one".utf8).write(to: file)

        let heard = expectation(description: "the watch reports the write")
        heard.assertForOverFulfill = false
        let watcher = FileWatcher(url: file) { heard.fulfill() }

        // Given to the run loop, not written from it: the source has to be
        // armed before the write it is meant to hear.
        DispatchQueue.main.async {
            try? Data("one and two".utf8).write(to: file)
        }
        wait(for: [heard], timeout: 5)
        watcher.stop()
    }

    func testTheWatchHearsATempFileRenamedOverTheOriginal() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("notes.txt")
        try Data("one".utf8).write(to: file)

        let heard = expectation(description: "the watch reports the rename")
        heard.assertForOverFulfill = false
        let watcher = FileWatcher(url: file) { heard.fulfill() }

        DispatchQueue.main.async {
            // What most editors do: a new file beside the old one, renamed
            // over the top. The descriptor the watch was opened on is on an
            // inode nobody can reach after this.
            let temporary = directory.appendingPathComponent("notes.txt.tmp")
            try? Data("rewritten by somebody else".utf8).write(to: temporary)
            try? FileManager.default.replaceItem(
                at: file, withItemAt: temporary, backupItemName: nil,
                options: [], resultingItemURL: nil
            )
        }
        wait(for: [heard], timeout: 5)
        watcher.stop()
    }

    // MARK: - A clean tab

    @MainActor
    func testACleanTabTakesTheNewTextSilently() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("notes.md")
        try Data("first draft".utf8).write(to: file)

        let controller = try makeController()
        controller.open(url: file)
        XCTAssertEqual(controller.openNotes.last?.text, "first draft")
        XCTAssertFalse(controller.currentTabState.isDirty)

        try rewrite(file, as: "somebody else's draft", in: controller)

        XCTAssertEqual(controller.openNotes.last?.text, "somebody else's draft",
                       "a clean tab simply takes what the file says now")
        XCTAssertFalse(controller.currentTabState.isDirty, "and is still clean")
        XCTAssertFalse(controller.externalChangeOffer.isShown,
                       "nothing was asked: there was nothing to lose")
        XCTAssertEqual(controller.tabStrip.marksForTesting.last.map(\.hasExternalChange), false)
    }

    @MainActor
    func testATempFileRenamedOverTheOriginalReloadsTheCleanTab() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("notes.md")
        try Data("first draft".utf8).write(to: file)

        let controller = try makeController()
        controller.open(url: file)

        let handled = expectation(description: "the change is dealt with")
        handled.assertForOverFulfill = false
        controller.onExternalChangeForTesting = { handled.fulfill() }
        DispatchQueue.main.async {
            let temporary = directory.appendingPathComponent("notes.md.tmp")
            try? Data("written the way every other editor writes".utf8).write(to: temporary)
            try? FileManager.default.replaceItem(
                at: file, withItemAt: temporary, backupItemName: nil,
                options: [], resultingItemURL: nil
            )
        }
        wait(for: [handled], timeout: 5)

        XCTAssertEqual(controller.openNotes.last?.text,
                       "written the way every other editor writes",
                       "a rename over the file is a change like any other")
    }

    @MainActor
    func testTheCaretKeepsItsPlaceAcrossAReload() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("notes.md")
        try Data("alpha\nbeta\ngamma\n".utf8).write(to: file)

        let controller = try makeController()
        controller.open(url: file)
        controller.editorScrolling.textView.setSelectedRange(NSRange(location: 8, length: 0))

        try rewrite(file, as: "alpha\nBETA\ngamma\n", in: controller)

        XCTAssertEqual(controller.editorScrolling.textView.selectedRange().location, 8,
                       "the same place in the note, since the new text is long enough")

        // Shorter than the caret's offset: as near as the text allows is its
        // end.
        try rewrite(file, as: "no", in: controller)
        XCTAssertEqual(controller.editorScrolling.textView.selectedRange().location, 2)
    }

    // MARK: - A dirty tab

    @MainActor
    func testADirtyTabIsMarkedAndOffersTheChoiceOnFocus() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("notes.md")
        try Data("first draft".utf8).write(to: file)

        let controller = try makeKeyController()
        controller.open(url: file)
        type(" — and mine", into: controller)
        XCTAssertTrue(controller.currentTabState.isDirty)

        try rewrite(file, as: "somebody else's draft", in: controller)

        XCTAssertEqual(controller.openNotes.last?.text, "first draft — and mine",
                       "the edits stand: nothing was reloaded over them")
        XCTAssertTrue(controller.currentTabState.isDirty)
        XCTAssertEqual(controller.tabStrip.marksForTesting.last.map(\.hasExternalChange), true,
                       "the tab wears the ring round its unsaved dot")
        XCTAssertTrue(controller.externalChangeOffer.isShown,
                      "the tab is the one in front, so the offer is standing on it")
    }

    @MainActor
    func testAMarkedTabMakesItsOfferWhenItComesToTheFront() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("notes.md")
        try Data("first draft".utf8).write(to: file)

        let controller = try makeKeyController()
        controller.open(url: file)
        type(" — and mine", into: controller)
        let watched = controller.selectedTabIndex
        controller.addTab()
        XCTAssertFalse(controller.externalChangeOffer.isShown)

        try rewrite(file, as: "somebody else's draft", in: controller)

        XCTAssertFalse(controller.externalChangeOffer.isShown,
                       "the marked tab is not the one being looked at")
        XCTAssertEqual(controller.tabStrip.marksForTesting[watched].hasExternalChange, true)

        controller.selectTab(at: watched)
        XCTAssertTrue(controller.externalChangeOffer.isShown, "on focus, and only then")
    }

    @MainActor
    func testOneOfferPerChangeAndNoMore() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("notes.md")
        try Data("first draft".utf8).write(to: file)

        let controller = try makeKeyController()
        controller.open(url: file)
        type(" — and mine", into: controller)
        try rewrite(file, as: "second hand", in: controller)
        XCTAssertTrue(controller.externalChangeOffer.isShown)

        // Keep mine: the buffer stands, the offer goes, and switching away
        // and back does not bring the same offer round again.
        controller.externalChangeOffer.wordsForTesting.keepMine.performClick(nil)
        XCTAssertFalse(controller.externalChangeOffer.isShown)
        let watched = controller.selectedTabIndex
        controller.addTab()
        controller.selectTab(at: watched)
        XCTAssertFalse(controller.externalChangeOffer.isShown,
                       "the choice was made; only a further change asks again")
        XCTAssertEqual(controller.tabStrip.marksForTesting[watched].hasExternalChange, true,
                       "the ring stays: the file really has moved")

        try rewrite(file, as: "third hand", in: controller)
        XCTAssertTrue(controller.externalChangeOffer.isShown, "a further change does ask")
    }

    @MainActor
    func testReloadTakesTheDiskTextAndClearsDirty() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("notes.md")
        try Data("first draft".utf8).write(to: file)

        let controller = try makeKeyController()
        controller.open(url: file)
        type(" — and mine", into: controller)
        try rewrite(file, as: "somebody else's draft", in: controller)

        controller.externalChangeOffer.wordsForTesting.reload.performClick(nil)

        XCTAssertEqual(controller.openNotes.last?.text, "somebody else's draft")
        XCTAssertFalse(controller.currentTabState.isDirty, "the edits are gone with the offer")
        XCTAssertFalse(controller.externalChangeOffer.isShown)
        XCTAssertEqual(controller.tabStrip.marksForTesting.last.map(\.hasExternalChange), false)
    }

    @MainActor
    func testKeepMineKeepsTheBufferAndTheNextSaveWritesIt() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("notes.md")
        try Data("first draft".utf8).write(to: file)

        let controller = try makeKeyController()
        controller.open(url: file)
        type(" — and mine", into: controller)
        try rewrite(file, as: "somebody else's draft", in: controller)

        controller.externalChangeOffer.wordsForTesting.keepMine.performClick(nil)
        XCTAssertEqual(controller.openNotes.last?.text, "first draft — and mine")
        XCTAssertTrue(controller.currentTabState.isDirty)

        controller.saveCurrent(forcePanel: false)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                       "first draft — and mine",
                       "⌘S writes over whatever the other hand put there")
        XCTAssertFalse(controller.currentTabState.isDirty)
        XCTAssertEqual(controller.tabStrip.marksForTesting.last.map(\.hasExternalChange), false,
                       "the file and the tab agree again")
    }

    // MARK: - Nota's own save

    @MainActor
    func testNotasOwnSaveNeverReloadsTheTab() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("notes.md")
        try Data("first draft".utf8).write(to: file)

        let controller = try makeController()
        controller.open(url: file)
        type(" — and mine", into: controller)

        let quiet = expectation(description: "no change is reported for our own write")
        quiet.isInverted = true
        controller.onExternalChangeForTesting = { quiet.fulfill() }
        controller.saveCurrent(forcePanel: false)
        wait(for: [quiet], timeout: 2)

        XCTAssertEqual(controller.openNotes.last?.text, "first draft — and mine")
        XCTAssertFalse(controller.currentTabState.isDirty)
        XCTAssertFalse(controller.externalChangeOffer.isShown)
    }

    // MARK: - A viewer

    @MainActor
    func testAPDFTabTakesTheDocumentTheFileHoldsNow() throws {
        let directory = try makeTemporaryDirectory()
        let pdf = try makePDF(pages: 1, at: directory.appendingPathComponent("paper.pdf"))

        let controller = try makeController()
        controller.open(url: pdf)
        XCTAssertEqual(controller.previewPanes.pdf.pageCount, 1)
        XCTAssertFalse(controller.currentTabState.isDirty, "a document is never dirty")

        let handled = expectation(description: "the change is dealt with")
        handled.assertForOverFulfill = false
        controller.onExternalChangeForTesting = { handled.fulfill() }
        DispatchQueue.main.async { [weak self] in
            _ = try? self?.makePDF(pages: 4, at: pdf)
        }
        wait(for: [handled], timeout: 5)

        XCTAssertEqual(controller.previewPanes.pdf.pageCount, 4,
                       "the document is read again, silently — there was nothing to ask about")
        XCTAssertFalse(controller.externalChangeOffer.isShown)
    }

    // MARK: - Helpers

    /// Writes `text` over `file` from the run loop — so the watch is armed
    /// before the write — and waits for the window to have dealt with it.
    @MainActor
    private func rewrite(
        _ file: URL, as text: String, in controller: MainWindowController,
        line: UInt = #line
    ) throws {
        let handled = expectation(description: "the change to \(file.lastPathComponent)")
        handled.assertForOverFulfill = false
        controller.onExternalChangeForTesting = { handled.fulfill() }
        DispatchQueue.main.async {
            try? Data(text.utf8).write(to: file)
        }
        wait(for: [handled], timeout: 5)
        controller.onExternalChangeForTesting = nil
    }

    /// Types at the end of the tab in front, which is also what makes it
    /// dirty. A file just opened leaves the caret at its start, and appending
    /// is what a reader coming back to a note does.
    @MainActor
    private func type(_ text: String, into controller: MainWindowController) {
        let textView = controller.editorScrolling.textView
        textView.setSelectedRange(NSRange(location: textView.textStorage?.length ?? 0, length: 0))
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    @MainActor
    private func makeController() throws -> MainWindowController {
        _ = NSApplication.shared
        let controller = MainWindowController(
            store: SessionStore(directory: try makeTemporaryDirectory())
        )
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.layoutIfNeeded()
        return controller
    }

    /// The same, with the window key: the offer only appears where the reader
    /// is actually looking.
    @MainActor
    private func makeKeyController() throws -> MainWindowController {
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()
        return controller
    }

    @discardableResult
    private func makePDF(pages: Int, at url: URL) throws -> URL {
        let document = PDFDocument()
        for index in 0 ..< pages {
            let page = PDFPage()
            page.setBounds(NSRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
            document.insert(page, at: index)
        }
        XCTAssertTrue(document.write(to: url), "the fixture has to be a real PDF")
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaExternalChangeTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
