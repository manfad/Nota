import AppKit
import Foundation
import XCTest
@testable import Nota

/// File › Open Recent: `NSDocumentController`'s own list, noted on every
/// named-file open and shown in a submenu Nota rebuilds by hand each time it
/// opens.
///
/// Nothing here should touch the reader's own recents — `NSDocumentController`
/// is one object for the whole process, so every test clears it going in and
/// coming out. The list is backed by `NSSharedFileList`, a system service one
/// call away rather than a plain array in this process, so a note or a clear
/// is not guaranteed to be visible the instant the call returns — every read
/// here waits for the state it expects rather than asserting on the spot.
final class OpenRecentTests: AppKitTestCase {
    private var temporaryDirectories: [URL] = []

    override func setUpWithError() throws {
        clearRecentDocuments()
    }

    override func tearDownWithError() throws {
        clearRecentDocuments()
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - Noting a document

    @MainActor
    func testOpeningANamedFileAddsItToTheRecentList() throws {
        let controller = try makeController()
        let file = try makeTextFile(named: "notes.md")

        controller.open(url: file)

        XCTAssertTrue(waitForRecentDocuments([file]), "opening a file should note it")
    }

    @MainActor
    func testComingBackToAnAlreadyOpenTabStillNotesTheDocument() throws {
        let controller = try makeController()
        let file = try makeTextFile(named: "notes.md")
        controller.open(url: file)
        XCTAssertTrue(waitForRecentDocuments([file]))
        clearRecentDocuments()

        // Opening it a second time takes the "already have a tab" branch —
        // no new tab, but still worth bumping in the recent list.
        controller.open(url: file)

        XCTAssertTrue(waitForRecentDocuments([file]), "reopening an open tab should note it too")
    }

    // A missing file's `open(url:)` runs `presentFailure`, which shows an
    // `NSAlert` with `runModal` — that hangs a test with nobody to click it,
    // the same reason `FileSniffTests` only checks `FileSniff.classify` for
    // its own refusals. Checked at that level instead: `.unreadable` is the
    // one case `open(url:)` never notes a recent document for.
    func testAMissingFileClassifiesAsUnreadable() throws {
        let missing = try makeTemporaryDirectory().appendingPathComponent("ghost.md")
        XCTAssertEqual(FileSniff.classify(at: missing), .unreadable)
    }

    // MARK: - The submenu

    @MainActor
    func testTheSubmenuListsWhatWasOpenedMostRecentFirst() throws {
        let controller = try makeController()
        let first = try makeTextFile(named: "first.md")
        let second = try makeTextFile(named: "second.md")
        controller.open(url: first)
        controller.open(url: second)

        let menu = NSMenu(title: "Open Recent")
        let recent = RecentDocumentsMenu { _ in }
        menu.delegate = recent
        let expected = [second.lastPathComponent, first.lastPathComponent]
        XCTAssertTrue(rebuildMenu(menu, with: recent) { items in
            items.compactMap { $0.representedObject as? URL }.map(\.lastPathComponent) == expected
        }, "most recently opened first")

        XCTAssertTrue(menu.items.contains { $0.isSeparatorItem })
        XCTAssertEqual(menu.items.last?.title, "Clear Menu")
    }

    @MainActor
    func testTheSubmenuIsRebuiltEachTimeItOpens() throws {
        let controller = try makeController()
        let first = try makeTextFile(named: "first.md")
        let second = try makeTextFile(named: "second.md")
        controller.open(url: first)

        let menu = NSMenu(title: "Open Recent")
        let recent = RecentDocumentsMenu { _ in }
        menu.delegate = recent
        XCTAssertTrue(rebuildMenu(menu, with: recent) { items in
            items.compactMap { $0.representedObject as? URL }.map(\.lastPathComponent) == ["first.md"]
        })

        // Opened after the menu was last built — a stale menu would still
        // say "first.md" alone.
        controller.open(url: second)
        let expected = ["second.md", "first.md"]
        XCTAssertTrue(rebuildMenu(menu, with: recent) { items in
            items.compactMap { $0.representedObject as? URL }.map(\.lastPathComponent) == expected
        })
    }

    @MainActor
    func testChoosingAnItemHandsBackItsURL() throws {
        let controller = try makeController()
        let file = try makeTextFile(named: "notes.md")
        controller.open(url: file)

        var chosen: URL?
        let menu = NSMenu(title: "Open Recent")
        let recent = RecentDocumentsMenu { chosen = $0 }
        menu.delegate = recent
        XCTAssertTrue(rebuildMenu(menu, with: recent) { items in
            items.contains { sameFile($0.representedObject as? URL, file) }
        })

        let index = try XCTUnwrap(
            menu.items.firstIndex { sameFile($0.representedObject as? URL, file) }
        )
        menu.performActionForItem(at: index)

        XCTAssertTrue(sameFile(chosen, file))
    }

    @MainActor
    func testClearMenuEmptiesTheRecentList() throws {
        let controller = try makeController()
        let file = try makeTextFile(named: "notes.md")
        controller.open(url: file)

        let menu = NSMenu(title: "Open Recent")
        let recent = RecentDocumentsMenu { _ in }
        menu.delegate = recent
        XCTAssertTrue(rebuildMenu(menu, with: recent) { items in
            items.contains { sameFile($0.representedObject as? URL, file) }
        })

        let clearIndex = try XCTUnwrap(menu.items.firstIndex { $0.title == "Clear Menu" })
        menu.performActionForItem(at: clearIndex)

        XCTAssertTrue(waitUntil { NSDocumentController.shared.recentDocumentURLs.isEmpty })

        // And the submenu itself comes back with nothing to choose from.
        XCTAssertTrue(rebuildMenu(menu, with: recent) { items in
            items.compactMap { $0.representedObject as? URL }.isEmpty
        })
        XCTAssertFalse(menu.items.contains { $0.isSeparatorItem })
        XCTAssertEqual(menu.items.map(\.title), ["Clear Menu"])
    }

    // MARK: - Helpers

    @MainActor
    private func makeController() throws -> MainWindowController {
        _ = NSApplication.shared
        let store = SessionStore(directory: try makeTemporaryDirectory())
        let controller = MainWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.layoutIfNeeded()
        return controller
    }

    private func makeTextFile(named name: String) throws -> URL {
        let url = try makeTemporaryDirectory().appendingPathComponent(name)
        try Data("hello".utf8).write(to: url)
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaOpenRecentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func clearRecentDocuments() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        _ = waitUntil { NSDocumentController.shared.recentDocumentURLs.isEmpty }
    }

    /// Waits for the recent list to read back exactly `urls`, in order —
    /// `NSSharedFileList` is a system service, so a note just made may not be
    /// visible to the very next read.
    private func waitForRecentDocuments(_ urls: [URL], timeout: TimeInterval = 2) -> Bool {
        waitUntil(timeout: timeout) {
            let list = NSDocumentController.shared.recentDocumentURLs
            guard list.count == urls.count else { return false }
            return zip(list, urls).allSatisfy { sameFile($0, $1) }
        }
    }

    /// Whether two URLs name the same fixture file. `NSDocumentController`
    /// hands recent documents back resolved through `/private/var/...`, while
    /// `FileManager`'s temporary directory is the unresolved `/var/...`
    /// symlink — exact `URL` equality does not see through that, so this
    /// compares the last two path components instead: the fixture's own
    /// unique temp-directory name and the file name, which together are
    /// unique enough for a test.
    private func sameFile(_ a: URL?, _ b: URL) -> Bool {
        guard let a else { return false }
        return a.pathComponents.suffix(2) == b.pathComponents.suffix(2)
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return condition() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    /// Rebuilds `menu` from `recent` until `condition` is happy with what
    /// landed, or gives up. Two separate reads of `recentDocumentURLs` a
    /// moment apart are not guaranteed to agree, so the build and the check
    /// run together on every attempt rather than one read feeding a later one.
    @discardableResult
    private func rebuildMenu(
        _ menu: NSMenu, with recent: RecentDocumentsMenu,
        timeout: TimeInterval = 2, until condition: ([NSMenuItem]) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            recent.menuNeedsUpdate(menu)
            if condition(menu.items) { return true }
            guard Date() < deadline else { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
