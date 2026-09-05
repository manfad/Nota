import AppKit
import Foundation
import XCTest
@testable import Nota

/// Bookmarks (SPEC Todo 13): the list itself, the session key that carries it
/// between launches, the badge on the tab, and the two picker lists that offer
/// them back.
final class BookmarksTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - The list

    func testTogglingAddsThenRemovesAndKeepsTheOrderTheyWereAddedIn() throws {
        let directory = try makeTemporaryDirectory()
        let first = try makeFile(named: "alpha.md", in: directory)
        let second = try makeFile(named: "beta.md", in: directory)
        let bookmarks = Bookmarks()

        XCTAssertTrue(bookmarks.isEmpty)
        XCTAssertTrue(bookmarks.toggle(first), "the first toggle bookmarks it")
        XCTAssertTrue(bookmarks.toggle(second))
        XCTAssertEqual(bookmarks.paths.map(Bookmarks.name(of:)), ["alpha.md", "beta.md"],
                       "order is the order they were added")
        XCTAssertTrue(bookmarks.contains(first))

        XCTAssertFalse(bookmarks.toggle(first), "the second toggle takes it off")
        XCTAssertFalse(bookmarks.contains(first))
        XCTAssertEqual(bookmarks.paths.map(Bookmarks.name(of:)), ["beta.md"])

        // Adding the same file twice is one bookmark, whichever spelling of
        // the path it arrives as.
        bookmarks.add(second)
        bookmarks.add(directory.appendingPathComponent("./beta.md"))
        XCTAssertEqual(bookmarks.paths.count, 1)
    }

    func testABookmarkWhoseFileHasGoneIsMissingButStaysInTheListUntilItIsRemoved() throws {
        let directory = try makeTemporaryDirectory()
        let kept = try makeFile(named: "kept.md", in: directory)
        let doomed = try makeFile(named: "doomed.md", in: directory)
        let bookmarks = Bookmarks()
        bookmarks.add(kept)
        bookmarks.add(doomed)

        try FileManager.default.removeItem(at: doomed)

        XCTAssertTrue(bookmarks.isMissing(doomed.path))
        XCTAssertFalse(bookmarks.isMissing(kept.path))
        XCTAssertTrue(bookmarks.hasMissing)
        XCTAssertEqual(bookmarks.missingPaths.map(Bookmarks.name(of:)), ["doomed.md"])
        XCTAssertEqual(bookmarks.paths.count, 2, "a missing file is still a bookmark")

        bookmarks.removeMissing()
        XCTAssertEqual(bookmarks.paths.map(Bookmarks.name(of:)), ["kept.md"])
        XCTAssertFalse(bookmarks.hasMissing)
    }

    // MARK: - The session file

    /// Every session written before Todo 13 has no `bookmarks` key at all,
    /// and has to open with none rather than refusing to decode.
    func testASessionWrittenBeforeBookmarksOpensWithNone() throws {
        let tab = UUID()
        let json = """
        {
          "fontSize": 13,
          "selectedTabID": "\(tab.uuidString)",
          "tabs": [
            {"id": "\(tab.uuidString)", "isDirty": false, "selection": 0,
             "untitledName": "Untitled"}
          ]
        }
        """

        let state = try JSONDecoder().decode(SessionState.self, from: Data(json.utf8))

        XCTAssertEqual(state.bookmarks, [])
        XCTAssertEqual(state.windows.first?.tabs.count, 1, "the rest of the file still reads")
    }

    func testBookmarksRoundTripThroughTheSessionFile() throws {
        let directory = try makeTemporaryDirectory()
        let store = SessionStore(directory: directory)
        let tab = UUID()
        let state = SessionState(
            tabs: [SessionTab(id: tab, path: nil, untitledName: "Untitled",
                              isDirty: false, selection: 0)],
            selectedTabID: tab,
            fontSize: 13,
            bookmarks: ["/tmp/alpha.md", "/tmp/beta.md"]
        )
        store.save(state)

        let reopened = try XCTUnwrap(SessionStore(directory: directory).load())
        XCTAssertEqual(reopened.bookmarks, ["/tmp/alpha.md", "/tmp/beta.md"])
        XCTAssertEqual(reopened, state)

        // And the key is really in the file, not just in the round trip.
        let raw = try Data(contentsOf: directory.appendingPathComponent("session.json"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(object["bookmarks"] as? [String], ["/tmp/alpha.md", "/tmp/beta.md"])
    }

    // MARK: - Bookmarking a tab

    @MainActor
    func testBookmarkingTheFrontTabBadgesItInTheStripAndWritesTheSession() throws {
        let directory = try makeTemporaryDirectory()
        let bench = try makeController(support: directory)
        let file = try makeFile(named: "notes.md", in: try makeTemporaryDirectory())
        bench.controller.open(url: file)

        XCTAssertFalse(bench.controller.currentTabIsBookmarked)
        XCTAssertTrue(bench.controller.canBookmarkCurrentTab)

        bench.controller.toggleBookmarkForCurrentTab()

        XCTAssertTrue(bench.controller.currentTabIsBookmarked)
        XCTAssertEqual(bench.controller.tabStrip.bookmarkBadgesForTesting, [false, true],
                       "only the bookmarked tab wears the badge")
        XCTAssertEqual(bench.store.load()?.bookmarks.map(Bookmarks.name(of:)), ["notes.md"],
                       "the session file learned about it straight away")

        bench.controller.toggleBookmarkForCurrentTab()
        XCTAssertFalse(bench.controller.currentTabIsBookmarked)
        XCTAssertEqual(bench.controller.tabStrip.bookmarkBadgesForTesting, [false, false])
        XCTAssertEqual(bench.store.load()?.bookmarks, [])
    }

    /// A note that has never been saved has no path to bookmark: ⇧⌘D asks it
    /// to be saved first, and a cancelled panel leaves it exactly as
    /// unbookmarked as it was.
    @MainActor
    func testAnUntitledNoteIsNotBookmarkedWhenTheSavePanelIsCancelled() throws {
        let bench = try makeController(support: try makeTemporaryDirectory())
        var panelsShown = 0
        bench.controller.savePanelProvider = { _ in
            panelsShown += 1
            return nil
        }

        bench.controller.toggleBookmarkForCurrentTab()

        XCTAssertEqual(panelsShown, 1, "it did ask for a name")
        XCTAssertFalse(bench.controller.currentTabIsBookmarked)
        XCTAssertEqual(bench.controller.bookmarks.paths, [])
        XCTAssertEqual(bench.controller.tabStrip.bookmarkBadgesForTesting, [false])
    }

    @MainActor
    func testAnUntitledNoteIsBookmarkedOnceTheSaveLands() throws {
        let bench = try makeController(support: try makeTemporaryDirectory())
        let destination = try makeTemporaryDirectory().appendingPathComponent("saved.md")
        bench.controller.savePanelProvider = { _ in destination }

        bench.controller.toggleBookmarkForCurrentTab()

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path),
                      "the save actually happened")
        XCTAssertTrue(bench.controller.currentTabIsBookmarked)
        XCTAssertEqual(bench.controller.bookmarks.paths.map(Bookmarks.name(of:)), ["saved.md"])
    }

    /// Right-click on a tab: bookmark it, or close it.
    @MainActor
    func testATabsContextMenuTogglesItsBookmark() throws {
        let bench = try makeController(support: try makeTemporaryDirectory())
        let file = try makeFile(named: "notes.md", in: try makeTemporaryDirectory())
        bench.controller.open(url: file)
        let strip = bench.controller.tabStrip

        let menu = try XCTUnwrap(strip.contextMenuForTesting(at: 1))
        XCTAssertEqual(menu.items.map(\.title), ["Bookmark", "Reveal in Finder", "", "Close Tab"])

        menu.performActionForItem(at: 0)
        XCTAssertTrue(bench.controller.currentTabIsBookmarked)

        // Reopened, the same item now offers to take it off again.
        let second = try XCTUnwrap(strip.contextMenuForTesting(at: 1))
        XCTAssertEqual(second.items.first?.title, "Remove Bookmark")
        second.performActionForItem(at: 0)
        XCTAssertFalse(bench.controller.currentTabIsBookmarked)
    }

    /// Right-click on a tab: show its file in the Finder. An untitled note
    /// has no file, so the item is greyed and does nothing.
    @MainActor
    func testATabsContextMenuRevealsItsFileInTheFinder() throws {
        let bench = try makeController(support: try makeTemporaryDirectory())
        let file = try makeFile(named: "notes.md", in: try makeTemporaryDirectory())
        bench.controller.open(url: file)
        var revealed: [URL] = []
        bench.controller.fileRevealer = { revealed = $0 }
        let strip = bench.controller.tabStrip

        let menu = try XCTUnwrap(strip.contextMenuForTesting(at: 1))
        XCTAssertTrue(menu.items[1].isEnabled)
        menu.performActionForItem(at: 1)
        XCTAssertEqual(revealed, [file.standardizedFileURL])
        XCTAssertTrue(bench.controller.currentTabHasFile)

        // The untitled tab the window opened with: greyed, and no URL goes out.
        revealed = []
        let untitled = try XCTUnwrap(strip.contextMenuForTesting(at: 0))
        XCTAssertFalse(untitled.items[1].isEnabled)
        bench.controller.revealInFinder(at: 0)
        XCTAssertEqual(revealed, [])
        bench.controller.selectTab(at: 0)
        XCTAssertFalse(bench.controller.currentTabHasFile)
    }

    // MARK: - The picker

    @MainActor
    func testTheStripsBookmarkButtonOpensThePickerOnTheBookmarksAlone() throws {
        let bench = try makeController(support: try makeTemporaryDirectory())
        let directory = try makeTemporaryDirectory()
        let alpha = try makeFile(named: "alpha.md", in: directory)
        let beta = try makeFile(named: "beta.md", in: directory)
        bench.controller.bookmarks.add(alpha)
        bench.controller.bookmarks.add(beta)

        bench.controller.tabStrip.pressBookmarksButtonForTesting()
        defer { bench.controller.tabPickerPanel.hide() }

        let picker = bench.controller.tabPickerPanel
        XCTAssertTrue(picker.isShowingBookmarks)
        XCTAssertEqual(picker.visibleRowTexts, ["alpha.md", "beta.md"],
                       "the open Untitled tab is not in this list")
        XCTAssertEqual(picker.visibleRowIsBookmark, [true, true])
        XCTAssertEqual(picker.visibleRowIsMissing, [false, false])

        // And it fuzzy-filters on the file name.
        picker.query = "bet"
        XCTAssertEqual(picker.visibleRowTexts, ["beta.md"])
    }

    @MainActor
    func testAMissingBookmarkIsGreyedAndReturnOnItDoesNothing() throws {
        let bench = try makeController(support: try makeTemporaryDirectory())
        let directory = try makeTemporaryDirectory()
        let ghost = try makeFile(named: "ghost.md", in: directory)
        bench.controller.bookmarks.add(ghost)
        try FileManager.default.removeItem(at: ghost)

        bench.controller.tabStrip.pressBookmarksButtonForTesting()
        let picker = bench.controller.tabPickerPanel
        defer { picker.hide() }

        XCTAssertEqual(picker.visibleRowTexts, ["ghost.md"])
        XCTAssertEqual(picker.visibleRowIsMissing, [true])

        picker.chooseSelection()
        XCTAssertTrue(picker.isVisible, "the panel stays up: there was nothing to open")
        XCTAssertEqual(bench.controller.openNotes.count, 1, "and no tab was opened")
    }

    @MainActor
    func testDeleteOnAPickerRowRemovesThatBookmark() throws {
        let bench = try makeController(support: try makeTemporaryDirectory())
        let directory = try makeTemporaryDirectory()
        let alpha = try makeFile(named: "alpha.md", in: directory)
        let beta = try makeFile(named: "beta.md", in: directory)
        bench.controller.bookmarks.add(alpha)
        bench.controller.bookmarks.add(beta)

        bench.controller.tabStrip.pressBookmarksButtonForTesting()
        let picker = bench.controller.tabPickerPanel
        defer { picker.hide() }

        XCTAssertTrue(picker.removeSelectedBookmark(), "the first row goes")

        XCTAssertEqual(picker.visibleRowTexts, ["beta.md"], "the panel stays up on the rest")
        XCTAssertEqual(bench.controller.bookmarks.paths.map(Bookmarks.name(of:)), ["beta.md"])
        XCTAssertEqual(bench.store.load()?.bookmarks.map(Bookmarks.name(of:)), ["beta.md"])

        XCTAssertTrue(picker.removeSelectedBookmark())
        XCTAssertTrue(picker.visibleRowTexts.isEmpty)
        XCTAssertFalse(picker.removeSelectedBookmark(), "nothing left to take")
    }

    /// ⌘P offers the bookmarks under the open tabs — but only the ones this
    /// window does not already have a tab for.
    @MainActor
    func testTheTabSwitcherListsBookmarksThatAreNotOpenUnderTheTabs() throws {
        let bench = try makeController(support: try makeTemporaryDirectory())
        let directory = try makeTemporaryDirectory()
        let open = try makeFile(named: "open.md", in: directory)
        let closed = try makeFile(named: "closed.md", in: directory)
        bench.controller.open(url: open)
        bench.controller.bookmarks.add(open)
        bench.controller.bookmarks.add(closed)

        bench.controller.showTabPicker()
        let picker = bench.controller.tabPickerPanel
        defer { picker.hide() }

        XCTAssertEqual(picker.visibleRowTexts, ["Untitled", "open.md", "closed.md"])
        XCTAssertEqual(picker.visibleRowIsBookmark, [false, false, true],
                       "the open bookmark is listed once, as a tab")
        XCTAssertEqual(picker.visibleRowSymbolNames.last, "bookmark",
                       "a bookmark row reads as one that is not open yet")
    }

    /// The two halves are ranked together — a bookmark that matches better
    /// than every open tab comes first — and a tie goes to the open tab.
    @MainActor
    func testAWellMatchedBookmarkOutranksTheTabsAndATieGoesToTheTab() throws {
        let bench = try makeController(support: try makeTemporaryDirectory())
        let directory = try makeTemporaryDirectory()
        let zebra = try makeFile(named: "zebra.md", in: directory)
        bench.controller.open(url: zebra)
        bench.controller.bookmarks.add(try makeFile(named: "quokka.md", in: directory))

        bench.controller.showTabPicker()
        let picker = bench.controller.tabPickerPanel
        defer { picker.hide() }

        picker.query = "quo"
        XCTAssertEqual(picker.visibleRowTexts, ["quokka.md"],
                       "a bookmark is offered on its own merits, not only under the tabs")

        // A query that matches nothing at all empties both halves.
        picker.query = "zzzz"
        XCTAssertTrue(picker.visibleRowTexts.isEmpty)
    }

    @MainActor
    func testChoosingABookmarkSelectsItsTabWhenOpenAndOpensItWhenNot() throws {
        let bench = try makeController(support: try makeTemporaryDirectory())
        let directory = try makeTemporaryDirectory()
        let open = try makeFile(named: "open.md", in: directory)
        let closed = try makeFile(named: "closed.md", in: directory)
        bench.controller.open(url: open)
        bench.controller.bookmarks.add(open)
        bench.controller.bookmarks.add(closed)
        // Stand somewhere else, so selecting the tab is a visible move.
        bench.controller.selectTab(at: 0)
        XCTAssertEqual(bench.controller.selectedTabIndex, 0)

        // Already open: a tab switch, and no second tab for the same file.
        bench.controller.openBookmark(path: open.path)
        XCTAssertEqual(bench.controller.selectedTabIndex, 1)
        XCTAssertEqual(bench.controller.openNotes.count, 2)

        // Not open: an ordinary open.
        bench.controller.openBookmark(path: closed.path)
        XCTAssertEqual(bench.controller.openNotes.count, 3)
        XCTAssertEqual(bench.controller.openNotes.last?.title, "closed.md")
    }

    // MARK: - The strip

    @MainActor
    func testTheBookmarkButtonSitsAtTheTrailingEdgePastThePlus() throws {
        let bench = try makeController(support: try makeTemporaryDirectory())
        let strip = bench.controller.tabStrip
        bench.window.layoutIfNeeded()
        strip.layoutSubtreeIfNeeded()

        let bookmark = strip.bookmarksButtonFrameForTesting
        let plus = strip.newTabButtonFrameForTesting

        XCTAssertEqual(bookmark.width, TabStripLayout.bookmarkSlot)
        XCTAssertGreaterThan(bookmark.minX, plus.maxX, "it sits past the +")
        XCTAssertLessThanOrEqual(bookmark.maxX, strip.bounds.maxX, "and inside the strip")
    }

    /// The Settings gear sits past the bookmark, the last thing before the
    /// reserve at the strip's end, and it opens the same window ⌘, does.
    @MainActor
    func testTheSettingsGearSitsPastTheBookmarkAndOpensSettings() throws {
        let bench = try makeController(support: try makeTemporaryDirectory())
        let strip = bench.controller.tabStrip
        bench.window.layoutIfNeeded()
        strip.layoutSubtreeIfNeeded()

        let bookmark = strip.bookmarksButtonFrameForTesting
        let gear = strip.settingsButtonFrameForTesting
        XCTAssertEqual(gear.width, TabStripLayout.settingsSlot)
        XCTAssertEqual(gear.minX, bookmark.maxX + TabStripLayout.bookmarkGap, accuracy: 0.5)
        XCTAssertLessThanOrEqual(gear.maxX, strip.bounds.maxX - TabStripLayout.trailingReserve)

        strip.pressSettingsButtonForTesting()
        XCTAssertTrue(SettingsWindowController.shared.window?.isVisible ?? false)
        SettingsWindowController.shared.window?.orderOut(nil)
    }

    // MARK: - The bookmarks panel's top row

    /// In the bookmarks panel the fixed row above the field is the front
    /// tab's bookmark, not "Add new tab": choosing it bookmarks the tab.
    @MainActor
    func testTheBookmarkPanelsTopRowBookmarksTheFrontTab() throws {
        let bench = try makeController(support: try makeTemporaryDirectory())
        let directory = try makeTemporaryDirectory()
        bench.controller.open(url: try makeFile(named: "alpha.md", in: directory))
        XCTAssertFalse(bench.controller.currentTabIsBookmarked)

        bench.controller.showBookmarksPicker()
        let picker = bench.controller.tabPickerPanel
        defer { picker.hide() }

        XCTAssertEqual(picker.topRowText, "Bookmark this tab")
        XCTAssertEqual(picker.topRowSymbol, "bookmark")
        XCTAssertTrue(picker.topRowIsEnabled)

        picker.moveSelectionUp()
        XCTAssertTrue(picker.isTopRowSelected, "nothing in the list, so ↑ reaches it")
        picker.chooseSelection()

        XCTAssertFalse(picker.isVisible, "choosing closes the panel")
        XCTAssertTrue(bench.controller.currentTabIsBookmarked)
        XCTAssertEqual(bench.controller.bookmarks.paths.map(Bookmarks.name(of:)), ["alpha.md"])
    }

    /// Over a tab that is already bookmarked the same row is the way back
    /// out again.
    @MainActor
    func testTheTopRowRemovesTheBookmarkWhenTheFrontTabHasOne() throws {
        let bench = try makeController(support: try makeTemporaryDirectory())
        let directory = try makeTemporaryDirectory()
        let alpha = try makeFile(named: "alpha.md", in: directory)
        bench.controller.open(url: alpha)
        bench.controller.toggleBookmarkForCurrentTab()
        XCTAssertTrue(bench.controller.currentTabIsBookmarked)

        bench.controller.showBookmarksPicker()
        let picker = bench.controller.tabPickerPanel
        defer { picker.hide() }

        XCTAssertEqual(picker.topRowText, "Remove bookmark from this tab")
        XCTAssertEqual(picker.topRowSymbol, "bookmark.fill")

        picker.moveSelectionUp()
        XCTAssertTrue(picker.isTopRowSelected, "↑ from the one list row reaches it")
        picker.chooseSelection()

        XCTAssertFalse(bench.controller.currentTabIsBookmarked)
        XCTAssertTrue(bench.controller.bookmarks.isEmpty)
    }

    /// With no tab to bookmark the row has nothing to do: it is inert, and
    /// ↑ leaves the selection where it was.
    @MainActor
    func testTheTopRowIsInertWithNoTabToBookmark() throws {
        let bench = try makeController(support: try makeTemporaryDirectory())
        let picker = TabPickerPanel()
        picker.showBookmarks(
            bookmarks: [],
            frontTab: (canBookmark: false, isBookmarked: false),
            over: bench.window
        )
        defer { picker.hide() }

        XCTAssertEqual(picker.topRowText, "Bookmark this tab")
        XCTAssertFalse(picker.topRowIsEnabled)

        picker.moveSelectionUp()
        XCTAssertFalse(picker.isTopRowSelected, "there is nothing for it to do")
        picker.chooseSelection()
        XCTAssertTrue(picker.isVisible, "and Return on nothing leaves the panel up")
    }

    // MARK: - Helpers

    @MainActor
    private func makeController(support: URL) throws
        -> (store: SessionStore, controller: MainWindowController, window: NSWindow) {
        _ = NSApplication.shared
        let store = SessionStore(directory: support)
        let controller = MainWindowController(store: store)
        controller.windowPresenter = { $0.makeKeyAndOrderFrontOffscreen() }
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFrontOffscreen()
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.layoutIfNeeded()
        return (store, controller, window)
    }

    private func makeFile(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("hello".utf8).write(to: url)
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaBookmarksTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
