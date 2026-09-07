import AppKit
import XCTest
@testable import Nota

/// ⌘F over a tree preview: what a query matches in the rows, where it lands,
/// what it bands, and what the editor's caret does about it.
final class TreeFindTests: AppKitTestCase {
    /// The pane holds its note weakly, the way the column does — so a test
    /// that made one has to keep it alive itself.
    private var heldNotes: [Note] = []
    private var windows: [NSWindow] = []
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows = []
        heldNotes = []
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    /// The file most of these are searched over: two `name`s, one of them
    /// inside a branch, so a query has somewhere to walk to.
    private static let settings = """
    {
      "name": "Nota",
      "window": {
        "name": "main",
        "size": 12
      }
    }
    """

    // MARK: - What a query matches

    @MainActor
    func testAKeyMatchLandsOnTheRowThatNamesIt() throws {
        let pane = try makePane(showing: Self.settings)
        pane.find.perform(.showFindInterface)
        type("window", into: pane.find.bar)

        XCTAssertEqual(pane.find.matches.count, 1)
        let match = try XCTUnwrap(pane.find.currentMatch)
        XCTAssertEqual(match.kind, .key)
        XCTAssertEqual(match.row.path, path("window"))
        XCTAssertEqual(pane.selectedPath, path("window"), "the row is selected")
    }

    @MainActor
    func testAValueMatchLandsOnTheRowThatShowsIt() throws {
        let pane = try makePane(showing: Self.settings)
        pane.find.perform(.showFindInterface)
        type("nota", into: pane.find.bar)

        let match = try XCTUnwrap(pane.find.currentMatch)
        XCTAssertEqual(match.kind, .value, "the value, matched case-insensitively")
        XCTAssertEqual(match.row.path, path("name"))
        // `name` then the two-space gap then `"Nota"`: the band is inside the
        // quotes the row draws, not at the start of the row.
        XCTAssertEqual(match.range, NSRange(location: 7, length: 4))
    }

    @MainActor
    func testTheCountReadsLikeEveryOtherBar() throws {
        let pane = try makePane(showing: Self.settings)
        let bar = pane.find.bar
        pane.find.perform(.showFindInterface)
        XCTAssertNil(bar.status, "nothing at all while the field is empty")

        type("name", into: bar)
        XCTAssertEqual(pane.find.matches.count, 2)
        XCTAssertEqual(bar.status, "1 of 2")

        pane.find.perform(.nextMatch)
        XCTAssertEqual(bar.status, "2 of 2")

        type("nowhere", into: bar)
        XCTAssertEqual(bar.status, "No matches")
    }

    /// A branch the reader had closed is opened to show what was found in it,
    /// and nothing else moves.
    @MainActor
    func testAMatchInsideAClosedBranchOpensEveryBranchAboveIt() throws {
        let pane = try makePane(showing: Self.settings)
        let branch = try XCTUnwrap(pane.outline.item(atRow: 2))
        pane.outline.collapseItem(branch)
        XCTAssertEqual(pane.visibleRows.map(\.title), ["{2}", "name  \"Nota\"", "window  {2}"])

        pane.find.perform(.showFindInterface)
        type("main", into: pane.find.bar)

        XCTAssertTrue(pane.outline.isItemExpanded(branch), "the branch was opened for the match")
        XCTAssertEqual(pane.selectedPath, path("window", "name"))
    }

    @MainActor
    func testNextAndPreviousWrapRound() throws {
        let pane = try makePane(showing: Self.settings)
        pane.find.perform(.showFindInterface)
        type("name", into: pane.find.bar)
        XCTAssertEqual(pane.selectedPath, path("name"))

        pane.find.perform(.nextMatch)
        XCTAssertEqual(pane.selectedPath, path("window", "name"))

        pane.find.perform(.nextMatch)
        XCTAssertEqual(pane.selectedPath, path("name"), "round the end of the tree")

        pane.find.perform(.previousMatch)
        XCTAssertEqual(pane.selectedPath, path("window", "name"), "and back round the start")
    }

    // MARK: - The caret beside it

    @MainActor
    func testTheEditorsCaretFollowsTheMatchedPart() throws {
        let pane = try makePane(showing: Self.settings)
        var revealed: [[NSRange]] = []
        pane.onSourceReveal = { revealed.append($0) }

        pane.find.perform(.showFindInterface)
        type("nota", into: pane.find.bar)
        XCTAssertEqual(revealed.compactMap(\.first).map { source(Self.settings, $0) },
                       ["\"Nota\""], "a value match gives the value alone")

        revealed = []
        type("window", into: pane.find.bar)
        XCTAssertEqual(revealed.count, 1)
        let range = try XCTUnwrap(revealed[0].first)
        let member = try XCTUnwrap(source(Self.settings, range))
        XCTAssertTrue(member.hasPrefix("\"window\": {"),
                      "a key match gives the whole member, got \(member)")
    }

    // MARK: - The bands

    @MainActor
    func testEveryMatchWearsABandAndTheCurrentOneIsLoud() throws {
        let pane = try makePane(showing: Self.settings)
        pane.find.perform(.showFindInterface)
        type("name", into: pane.find.bar)

        let first = try XCTUnwrap(band(atRow: 1, location: 0, in: pane))
        XCTAssertEqual(first, TreeFindSession.currentBand, "the one being stood on")
        let second = try XCTUnwrap(band(atRow: 3, location: 0, in: pane))
        XCTAssertEqual(second, TreeFindSession.quietBand, "the other one, quietly")

        pane.find.perform(.nextMatch)
        XCTAssertEqual(band(atRow: 1, location: 0, in: pane), TreeFindSession.quietBand)
        XCTAssertEqual(band(atRow: 3, location: 0, in: pane), TreeFindSession.currentBand)
    }

    @MainActor
    func testEscapeTakesTheBandsDownAndLeavesTheRowSelected() throws {
        let pane = try makePane(showing: Self.settings)
        pane.find.perform(.showFindInterface)
        type("main", into: pane.find.bar)
        XCTAssertNotNil(band(atRow: 3, location: 8, in: pane))

        pane.find.perform(.hideFindInterface)
        XCTAssertFalse(pane.find.bar.isShown)
        XCTAssertNil(band(atRow: 3, location: 8, in: pane), "the bands go")
        XCTAssertEqual(pane.selectedPath, path("window", "name"),
                       "the row the reader landed on stays")
    }

    // MARK: - Whose ⌘F it is

    /// In reading mode the tree has the keyboard and Find… is its own; in
    /// split the editor has it and the item is left to the editor, whatever
    /// was last clicked in the column.
    @MainActor
    func testTheFindMenuIsTheTreesInReadingAndTheEditorsInSplit() throws {
        let pane = try makePane(showing: Self.settings)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = pane
        window.makeKeyAndOrderFrontOffscreen()
        windows.append(window)
        let outline = try XCTUnwrap(pane.outline as? NSUserInterfaceValidations)

        pane.takesKeyboard = true
        XCTAssertTrue(window.makeFirstResponder(pane.outline))
        XCTAssertTrue(outline.validateUserInterfaceItem(finderItem(.showFindInterface)))
        XCTAssertFalse(outline.validateUserInterfaceItem(finderItem(.replaceAll)),
                       "there is nothing in a tree to replace")

        pane.takesKeyboard = false
        XCTAssertTrue(outline.validateUserInterfaceItem(finderItem(.showFindInterface)),
                      "the item stays enabled — in split the answer is the editor's")
        pane.outline.performTextFinderAction(finderItem(.showFindInterface))
        XCTAssertFalse(pane.find.bar.isShown, "and the action never reaches the tree")
    }

    /// And the item is handed *on*, not dropped. Implementing the selector at
    /// all makes the outline the target, so a click on a row would otherwise
    /// grey ⌘F out: the action goes up the chain to the window controller,
    /// which opens the editor's own bar.
    @MainActor
    func testInSplitTheOutlineHandsCommandFUpToTheEditor() throws {
        let controller = try makeController(showing: Self.settings, named: "Settings.json")
        defer { controller.window?.orderOut(nil) }
        let pane = controller.previewPanes.tree
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.makeFirstResponder(pane.outline))
        XCTAssertFalse(pane.takesKeyboard, "split: the tree is not what is being read")

        let outline = try XCTUnwrap(pane.outline as? NSUserInterfaceValidations)
        XCTAssertTrue(outline.validateUserInterfaceItem(finderItem(.showFindInterface)),
                      "⌘F stays enabled with a row clicked")
        XCTAssertTrue(outline.validateUserInterfaceItem(finderItem(.replaceAll)),
                      "and so does the replace half, which is the editor's own")

        pane.outline.performTextFinderAction(finderItem(.showFindInterface))
        XCTAssertFalse(pane.find.bar.isShown, "the tree's pill stayed down")
        let shown = allFindBars(in: controller).filter(\.isShown)
        XCTAssertEqual(shown.count, 1, "the editor's, and only that one")
        XCTAssertFalse(shown.first === pane.find.bar)
    }

    // MARK: - A file being typed in

    @MainActor
    func testTheQuerySurvivesAReParse() throws {
        let pane = try makePane(showing: Self.settings)
        pane.find.perform(.showFindInterface)
        type("name", into: pane.find.bar)
        XCTAssertEqual(pane.find.matches.count, 2)

        let note = try XCTUnwrap(heldNotes.last)
        note.storage.mutableString.setString("""
        {
          "name": "Nota",
          "window": {
            "name": "main",
            "size": 12
          },
          "name": "again"
        }
        """)
        pane.show(note, in: PreviewContext(
            font: .systemFont(ofSize: 13), assets: nil, isVisible: true
        ))

        XCTAssertEqual(pane.find.query, "name")
        XCTAssertEqual(pane.find.matches.count, 3, "the query ran again over the new rows")
        XCTAssertEqual(pane.find.currentMatch?.row.path, path("name"),
                       "and the match being stood on is still the one it was")
    }

    // MARK: - The other grammars

    @MainActor
    func testAYAMLTreeIsSearchedTheSameWay() throws {
        let pane = try makePane(showing: """
        name: Nota
        window:
          title: main
        """, named: "config.yaml")
        pane.find.perform(.showFindInterface)
        type("main", into: pane.find.bar)

        XCTAssertEqual(pane.find.bar.status, "1 of 1")
        XCTAssertEqual(pane.selectedPath, path("window", "title"))
        XCTAssertEqual(pane.find.currentMatch?.kind, .value)
    }

    // MARK: - Helpers

    /// A query typed into the field, as AppKit reports it.
    @MainActor
    private func type(_ query: String, into bar: FindBarView) {
        bar.query = query
        bar.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: bar.field)
        )
    }

    /// The route the Find menu takes: a nil-targeted item tagged with the
    /// finder action.
    private func finderItem(_ action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem(
            title: "Find", action: #selector(NSResponder.performTextFinderAction(_:)),
            keyEquivalent: ""
        )
        item.tag = action.rawValue
        return item
    }

    /// The band a drawn row is wearing at a place in its own text — read off
    /// the field the outline actually puts on screen.
    @MainActor
    private func band(atRow index: Int, location: Int, in pane: TreePreviewView) -> NSColor? {
        guard let field = pane.outline.view(atColumn: 0, row: index, makeIfNecessary: true)
            as? NSTextField
        else { return nil }
        let title = field.attributedStringValue
        guard location < title.length else { return nil }
        return title.attribute(.backgroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    private func source(_ text: String, _ range: NSRange) -> String? {
        guard NSMaxRange(range) <= (text as NSString).length else { return nil }
        return (text as NSString).substring(with: range)
    }

    /// The path the tree spells a node with: the document's roots are
    /// numbered, and every step down adds its key or its own index.
    private func path(_ components: String...) -> String {
        (["0"] + components).joined(separator: "\u{1F}")
    }

    /// A pane on its own, showing one file — no window, no modes, just the
    /// tree the parser made.
    @MainActor
    private func makePane(
        showing text: String, named name: String = "Settings.json"
    ) throws -> TreePreviewView {
        _ = NSApplication.shared
        let pane = TreePreviewView(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
        pane.layoutSubtreeIfNeeded()
        let note = makeNote(named: name, text: text)
        heldNotes.append(note)
        pane.show(note, in: PreviewContext(
            font: .systemFont(ofSize: 13), assets: nil, isVisible: true
        ))
        return pane
    }

    private func makeNote(named name: String, text: String) -> Note {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaTreeFind-\(UUID().uuidString)")
            .appendingPathComponent(name)
        return Note(fileURL: url, untitledName: nil, text: text,
                    attributes: [:], assets: nil)
    }

    /// A whole window, in split, with the file open in it — what a test of
    /// whose ⌘F it is needs, since the answer is a walk up the responder
    /// chain.
    @MainActor
    private func makeController(
        showing text: String, named name: String
    ) throws -> MainWindowController {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        let store = SessionStore(directory: directory)
        let id = UUID()
        store.save(SessionState(
            tabs: [SessionTab(
                id: id, path: file.path, untitledName: nil, isDirty: false,
                selection: 0, format: .default, previewMode: .split
            )],
            selectedTabID: id,
            fontSize: 13
        ))
        let controller = MainWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1100, height: 620))
        window.makeKeyAndOrderFrontOffscreen()
        window.layoutIfNeeded()
        windows.append(window)
        return controller
    }

    /// Every find pill in the window — the editor's and the tree's — so a
    /// test can say which one of them came up.
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

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaTreeFindTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
