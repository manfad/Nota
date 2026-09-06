import AppKit
import Foundation
import XCTest
@testable import Nota

/// Nota with more than one window: the session file that holds them, moving a
/// note from one window to another, and where a closing window's tabs go.
/// Nothing here uses the mouse — the tear-off gesture is built on top of this
/// and has to be able to ask for the same moves outright.
final class MultiWindowTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - The session file

    func testASessionWrittenBeforeMultiWindowIsOneWindow() throws {
        let first = UUID()
        let second = UUID()
        let json = """
        {
          "fontSize": 15,
          "selectedTabID": "\(second.uuidString)",
          "tabs": [
            {"id": "\(first.uuidString)", "isDirty": true, "selection": 12,
             "path": "/tmp/notes.txt"},
            {"id": "\(second.uuidString)", "isDirty": false, "selection": 0,
             "untitledName": "Untitled 2"}
          ]
        }
        """

        let state = try JSONDecoder().decode(SessionState.self, from: Data(json.utf8))

        XCTAssertEqual(state.windows.count, 1, "the flat tab list is one window")
        XCTAssertEqual(state.windows.first?.tabs.map(\.id), [first, second])
        XCTAssertEqual(state.windows.first?.selectedTabID, second)
        XCTAssertNil(state.windows.first?.frame, "the old file never said where it sat")
        XCTAssertEqual(state.fontSize, 15)
    }

    func testTwoWindowsRoundTripThroughDisk() throws {
        let directory = try makeTemporaryDirectory()
        let store = SessionStore(directory: directory)
        let left = UUID()
        let right = UUID()

        let state = SessionState(
            windows: [
                SessionWindow(
                    tabs: [SessionTab(id: left, path: "/tmp/left.md", untitledName: nil,
                                      isDirty: false, selection: 4)],
                    selectedTabID: left,
                    frame: SessionFrame(x: 100, y: 200, width: 820, height: 560)
                ),
                SessionWindow(
                    tabs: [SessionTab(id: right, path: nil, untitledName: "Untitled",
                                      isDirty: true, selection: 0)],
                    selectedTabID: right
                ),
            ],
            fontSize: 14
        )
        store.save(state)

        let reopened = try XCTUnwrap(SessionStore(directory: directory).load())
        XCTAssertEqual(reopened, state)
        XCTAssertEqual(reopened.windows.count, 2)
        XCTAssertEqual(reopened.windows[0].frame?.rect,
                       CGRect(x: 100, y: 200, width: 820, height: 560))
        XCTAssertNil(reopened.windows[1].frame)
    }

    func testTheFlatTabListStillMirrorsTheFirstWindow() throws {
        let directory = try makeTemporaryDirectory()
        let store = SessionStore(directory: directory)
        let left = UUID()
        let right = UUID()
        let state = SessionState(
            windows: [
                SessionWindow(tabs: [SessionTab(id: left, path: nil, untitledName: "Untitled",
                                                isDirty: false, selection: 0)],
                              selectedTabID: left),
                SessionWindow(tabs: [SessionTab(id: right, path: nil, untitledName: "Untitled",
                                                isDirty: false, selection: 0)],
                              selectedTabID: right),
            ],
            fontSize: 13
        )
        store.save(state)

        let raw = try Data(contentsOf: directory.appendingPathComponent("session.json"))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        )
        XCTAssertEqual((object["windows"] as? [Any])?.count, 2)
        // A build from before multi-window reads these two keys and nothing
        // else: it has to find the first window there.
        let flat = try XCTUnwrap(object["tabs"] as? [[String: Any]])
        XCTAssertEqual(flat.count, 1)
        XCTAssertEqual(flat.first?["id"] as? String, left.uuidString)
        XCTAssertEqual(object["selectedTabID"] as? String, left.uuidString)
        XCTAssertEqual(state.tabs, state.windows[0].tabs)
    }

    // MARK: - Moving a note between windows

    @MainActor
    func testADetachedNoteKeepsItselfAndTheSourceSelectsANeighbour() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let store = SessionStore(directory: directory)
        let source = MainWindowController(store: store)
        type("alpha", into: source)
        source.addTab()
        type("beta", into: source)
        source.addTab()
        type("gamma", into: source)
        source.selectTab(at: 1)

        let detachedID = source.sessionWindow.tabs[1].id
        let note = try XCTUnwrap(source.detachNote(at: 1))

        XCTAssertEqual(note.id, detachedID, "it is the same note, not a copy")
        XCTAssertEqual(note.text, "beta")
        XCTAssertTrue(note.isDirty, "an unsaved edit does not stop being one")
        XCTAssertEqual(store.readText(for: note.id), "beta",
                       "the cached text stays: the note is moving, not closing")
        XCTAssertEqual(source.openNotes.map(\.text), ["alpha", "gamma"])
        XCTAssertEqual(source.selectedTabIndex, 1, "the neighbour takes its place")

        let destination = MainWindowController(store: store, restoring: SessionWindow(tabs: []))
        destination.attach(note, at: nil, select: true)

        XCTAssertEqual(destination.openNotes.map(\.text), ["", "beta"])
        XCTAssertEqual(destination.selectedTabIndex, 1)
        XCTAssertTrue(destination.currentTabState.isDirty)
        XCTAssertTrue(destination.editorScrolling.textView.textStorage === note.storage,
                      "the note's own storage — and its undo history — moved with it")
    }

    @MainActor
    func testDetachingTheLastTabLeavesAnUntitledOneUnlessTheWindowIsGoing() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let store = SessionStore(directory: directory)

        let keeping = MainWindowController(store: store)
        type("solo", into: keeping)
        let kept = try XCTUnwrap(keeping.detachNote(at: 0, keepingOneTab: true))
        XCTAssertEqual(kept.text, "solo")
        XCTAssertEqual(keeping.openNotes.map(\.text), [""], "a strip is never empty")
        XCTAssertEqual(keeping.openNotes.map(\.title), ["Untitled"])

        let closing = MainWindowController(
            store: SessionStore(directory: try makeTemporaryDirectory())
        )
        type("last", into: closing)
        let taken = try XCTUnwrap(closing.detachNote(at: 0, keepingOneTab: false))
        XCTAssertEqual(taken.text, "last")
        XCTAssertTrue(closing.openNotes.isEmpty, "the window is on its way out")
    }

    // MARK: - The window list

    @MainActor
    func testANewWindowTakesTheNoteAndTheOldOneLosesIt() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let store = SessionStore(directory: directory)
        let registry = WindowRegistry(store: store)
        let source = MainWindowController(store: store)
        registry.add(source)
        type("alpha", into: source)
        source.addTab()
        type("beta", into: source)

        let note = try XCTUnwrap(source.detachNote(at: 1))
        let torn = registry.newWindow(with: note)

        XCTAssertEqual(registry.controllers.count, 2)
        XCTAssertTrue(registry.controllers.last === torn)
        XCTAssertEqual(torn.openNotes.map(\.text), ["beta"])
        XCTAssertEqual(source.openNotes.map(\.text), ["alpha"])

        // One `SessionWindow` per window, and the flat mirror is the first.
        let state = try XCTUnwrap(store.load())
        XCTAssertEqual(state.windows.count, 2)
        XCTAssertEqual(state.windows.map { $0.tabs.count }, [1, 1])
        XCTAssertEqual(state.windows[1].tabs.first?.id, note.id)
        XCTAssertEqual(state.tabs, state.windows[0].tabs)
    }

    @MainActor
    func testClosingAWindowHandsItsTabsToTheOneBeforeIt() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let store = SessionStore(directory: directory)
        let registry = WindowRegistry(store: store)
        let source = MainWindowController(store: store)
        registry.add(source)
        type("alpha", into: source)
        source.addTab()
        type("beta", into: source)

        let note = try XCTUnwrap(source.detachNote(at: 1))
        let torn = registry.newWindow(with: note)

        XCTAssertTrue(registry.windowShouldClose(torn), "a second window really closes")
        XCTAssertEqual(registry.controllers.count, 1)
        XCTAssertEqual(source.openNotes.map(\.text), ["alpha", "beta"],
                       "no note is lost and nothing is asked")
        XCTAssertEqual(source.selectedTabIndex, 0, "the window it lands in keeps its place")
        XCTAssertEqual(try XCTUnwrap(store.load()).windows.count, 1)

        XCTAssertFalse(registry.windowShouldClose(source),
                       "the last window only hides, the way it always did")
        XCTAssertEqual(registry.controllers.count, 1)
    }

    // MARK: - ⌘W on the only tab

    /// Closing the only tab closes the tab and then the window goes the way
    /// closing the window goes: a lone window hides, a second window closes
    /// for real and hands its (fresh, blank) tab to the one before it —
    /// exactly as the title-bar close button would.
    @MainActor
    func testClosingTheOnlyTabGoesTheWayClosingTheWindowGoes() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let store = SessionStore(directory: directory)
        let registry = WindowRegistry(store: store)

        let lone = MainWindowController(store: store)
        registry.add(lone)
        lone.window?.makeKeyAndOrderFrontOffscreen()

        lone.closeTab(at: 0)

        XCTAssertEqual(lone.openNotes.map(\.text), [""], "a strip is never empty")
        XCTAssertEqual(lone.openNotes.map(\.title), ["Untitled"])
        XCTAssertEqual(lone.window?.isVisible, false, "the last window only hides")
        XCTAssertEqual(registry.controllers.count, 1, "hiding keeps it around to be summoned back")

        let other = registry.newWindow()
        other.window?.makeKeyAndOrderFrontOffscreen()
        XCTAssertEqual(registry.controllers.count, 2)

        other.closeTab(at: 0)

        XCTAssertEqual(registry.controllers.count, 1, "a second window really closes")
        XCTAssertTrue(registry.controllers.first === lone, "the one before it took its tab")
    }

    /// Closing one of two tabs is an ordinary tab close: the window stays
    /// open and untouched, holding the tab that is left.
    @MainActor
    func testClosingOneOfTwoTabsLeavesTheWindowOpenWithTheOther() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let store = SessionStore(directory: directory)
        let registry = WindowRegistry(store: store)
        let source = MainWindowController(store: store)
        registry.add(source)
        source.window?.makeKeyAndOrderFrontOffscreen()
        // Tab 0 stays clean so the close needs no save-changes prompt; only
        // the tab that is kept has an edit in it.
        source.addTab()
        type("beta", into: source)

        source.closeTab(at: 0)

        XCTAssertEqual(source.openNotes.map(\.text), ["beta"])
        XCTAssertEqual(source.window?.isVisible, true, "the window was never asked to close")
        XCTAssertEqual(registry.controllers.count, 1)
    }

    /// Cancelling the save-changes prompt on a dirty last tab leaves it,
    /// and the window, exactly as they were — the same as any other close.
    @MainActor
    func testCancellingTheDirtyPromptOnTheLastTabKeepsItAndTheWindow() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let store = SessionStore(directory: directory)
        let registry = WindowRegistry(store: store)
        let source = MainWindowController(store: store)
        registry.add(source)
        source.window?.makeKeyAndOrderFrontOffscreen()
        type("unsaved", into: source)
        source.confirmDiscardOverrideForTesting = { .alertThirdButtonReturn }

        source.closeTab(at: 0)

        XCTAssertEqual(source.openNotes.map(\.text), ["unsaved"], "the dirty tab is still there")
        XCTAssertEqual(source.window?.isVisible, true, "cancelling asks for nothing to close")
        XCTAssertEqual(registry.controllers.count, 1)
    }

    @MainActor
    func testTheActiveWindowIsTheOneThatWasLastInFront() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let store = SessionStore(directory: directory)
        let registry = WindowRegistry(store: store)
        let first = MainWindowController(store: store)
        registry.add(first)
        let second = registry.newWindow()

        XCTAssertTrue(registry.activeController === first, "the first one opened, until told")
        registry.markKey(try XCTUnwrap(second.window))
        XCTAssertTrue(registry.activeController === second)

        registry.removeWindow(second)
        XCTAssertTrue(registry.activeController === first,
                      "a window that is gone is not the active one")
    }

    @MainActor
    func testAWindowComesBackTheSizeItWas() throws {
        _ = NSApplication.shared
        let directory = try makeTemporaryDirectory()
        let store = SessionStore(directory: directory)
        let controller = MainWindowController(store: store)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 700, height: 480))
        controller.flushAll()

        let saved = try XCTUnwrap(store.load()).windows.first?.frame
        XCTAssertEqual(saved?.rect.size, window.frame.size)

        let relaunched = MainWindowController(store: SessionStore(directory: directory))
        XCTAssertEqual(relaunched.window?.frame.size, window.frame.size)
    }

    // MARK: - Tearing a tab off into a window of its own

    /// The gesture's first half: the tab leaves the strip, a window is built
    /// around it, and that window sits exactly where the tab was — the tab
    /// under the pointer, the same size as the window it came from. From
    /// there the window follows the pointer one to one.
    @MainActor
    func testATornOffTabGetsAWindowUnderThePointer() throws {
        // The strip's inset depends on which side the sidebar lives on, and
        // so does where a torn-off tab lands; pin the side rather than read
        // whatever this Mac's preference happens to be.
        let originalSide = Preferences.shared.sidebarSide
        Preferences.shared.sidebarSide = .right
        defer { Preferences.shared.sidebarSide = originalSide }
        let bench = try makeBench()
        bench.source.window?.makeKeyAndOrderFrontOffscreen()
        type("alpha", into: bench.source)
        bench.source.addTab()
        type("beta", into: bench.source)

        let grabOffset = NSPoint(x: 30, y: 12)
        let pointer = NSPoint(x: -19_500, y: -19_500)
        bench.source.tabBar(bench.source.tabStrip, tearOff: 1,
                            grabOffset: grabOffset, screenPoint: pointer)

        XCTAssertEqual(bench.registry.controllers.count, 2)
        let torn = try XCTUnwrap(bench.registry.controllers.last)
        XCTAssertEqual(torn.openNotes.map(\.text), ["beta"])
        XCTAssertEqual(bench.source.openNotes.map(\.text), ["alpha"])
        XCTAssertEqual(bench.source.window?.isVisible, true, "the window it left is still there")

        let frame = try XCTUnwrap(torn.window?.frame)
        XCTAssertEqual(frame.size, try XCTUnwrap(bench.source.window?.frame.size),
                       "the same size as the window it came from")
        XCTAssertEqual(frame.minX + MainWindowController.tabStripLeadingInset + grabOffset.x,
                       pointer.x, accuracy: 0.5,
                       "the first tab in the new strip sits under the pointer")
        XCTAssertEqual(frame.maxY - TabBarView.height / 2, pointer.y, accuracy: 0.5,
                       "and at the height it was grabbed at")

        bench.source.tabBarDragMoved(bench.source.tabStrip,
                                     to: NSPoint(x: pointer.x + 40, y: pointer.y - 25))
        let moved = try XCTUnwrap(torn.window?.frame)
        XCTAssertEqual(moved.minX, frame.minX + 40, accuracy: 0.5)
        XCTAssertEqual(moved.minY, frame.minY - 25, accuracy: 0.5)

        // Released over nothing, the new window simply stays where it is.
        bench.source.tabBarDragEnded(bench.source.tabStrip, committed: true,
                                     at: NSPoint(x: pointer.x + 40, y: pointer.y - 25))
        XCTAssertEqual(bench.registry.controllers.count, 2)
        let state = try XCTUnwrap(bench.store.load())
        XCTAssertEqual(state.windows.map { $0.tabs.count }, [1, 1],
                       "one session window per window that is still open")
    }

    /// A window whose only tab is dragged out has nothing left to show. It
    /// goes out of the way at once — the gesture is still running inside its
    /// tab view — and is gone from the app when the tab is dropped.
    @MainActor
    func testTearingOffTheLastTabTakesTheWindowWithIt() throws {
        let bench = try makeBench(showing: true)
        bench.source.window?.makeKeyAndOrderFrontOffscreen()
        type("solo", into: bench.source)

        let pointer = NSPoint(x: -19_500, y: -19_500)
        bench.source.tabBar(bench.source.tabStrip, tearOff: 0,
                            grabOffset: NSPoint(x: 20, y: 12), screenPoint: pointer)

        XCTAssertTrue(bench.source.openNotes.isEmpty, "no untitled tab is invented for it")
        XCTAssertEqual(bench.source.window?.isVisible, false, "the empty window is out of the way")
        XCTAssertEqual(bench.registry.controllers.count, 2, "both are on the list mid-gesture")
        let torn = try XCTUnwrap(bench.registry.controllers.last)
        XCTAssertEqual(torn.openNotes.map(\.text), ["solo"])

        bench.source.tabBarDragEnded(bench.source.tabStrip, committed: true, at: pointer)

        XCTAssertEqual(bench.registry.controllers.count, 1)
        XCTAssertTrue(bench.registry.controllers.first === torn, "the window the tab is in is the one left")
        XCTAssertEqual(try XCTUnwrap(bench.store.load()).windows.map { $0.tabs.count }, [1])
    }

    /// Esc abandons the whole gesture: the tab goes back to the slot it came
    /// from and the window it briefly had never happened.
    @MainActor
    func testEscapePutsTheTornTabBackWhereItCameFrom() throws {
        let bench = try makeBench()
        bench.source.window?.makeKeyAndOrderFrontOffscreen()
        type("alpha", into: bench.source)
        bench.source.addTab()
        type("beta", into: bench.source)

        let pointer = NSPoint(x: -19_500, y: -19_500)
        bench.source.tabBar(bench.source.tabStrip, tearOff: 0,
                            grabOffset: NSPoint(x: 20, y: 12), screenPoint: pointer)
        XCTAssertEqual(bench.source.openNotes.map(\.text), ["beta"])

        bench.source.tabBarDragEnded(bench.source.tabStrip, committed: false, at: pointer)

        XCTAssertEqual(bench.source.openNotes.map(\.text), ["alpha", "beta"],
                       "back in the slot it was dragged out of")
        XCTAssertEqual(bench.source.selectedTabIndex, 0)
        XCTAssertEqual(bench.registry.controllers.count, 1, "the extra window is gone")
        XCTAssertEqual(try XCTUnwrap(bench.store.load()).windows.map { $0.tabs.count }, [2])
    }

    /// Esc after the last tab was torn out brings the emptied window back
    /// rather than leaving the app with nothing on screen.
    @MainActor
    func testEscapeAfterTheLastTabBringsTheEmptiedWindowBack() throws {
        let bench = try makeBench(showing: true)
        bench.source.window?.makeKeyAndOrderFrontOffscreen()
        type("solo", into: bench.source)

        let pointer = NSPoint(x: -19_500, y: -19_500)
        bench.source.tabBar(bench.source.tabStrip, tearOff: 0,
                            grabOffset: NSPoint(x: 20, y: 12), screenPoint: pointer)
        XCTAssertEqual(bench.source.window?.isVisible, false)

        bench.source.tabBarDragEnded(bench.source.tabStrip, committed: false, at: pointer)

        XCTAssertEqual(bench.source.openNotes.map(\.text), ["solo"])
        XCTAssertEqual(bench.source.window?.isVisible, true, "the window it came from is back")
        XCTAssertEqual(bench.registry.controllers.count, 1)
    }

    /// Dropped on another window's strip, the tab docks there at the slot
    /// the caret was showing, and the window that carried it goes away.
    @MainActor
    func testDroppingOnAnotherWindowsStripDocksTheTabThere() throws {
        let bench = try makeBench()
        bench.source.window?.makeKeyAndOrderFrontOffscreen()
        type("alpha", into: bench.source)
        bench.source.addTab()
        type("beta", into: bench.source)

        let other = bench.registry.newWindow()
        other.windowPresenter = { _ in }
        let otherFrame = NSRect(x: -19_000, y: -19_000, width: 820, height: 560)
        other.window?.setFrame(otherFrame, display: false)
        other.window?.contentView?.layoutSubtreeIfNeeded()
        // The window server does not hit-test windows parked off every
        // display, so the test says outright which window is under the
        // pointer; everything downstream of that is the real thing.
        bench.source.dockTargetFinder = { [weak other] _, _ in other }

        // Just inside the leading edge of the other window's first tab.
        let drop = NSPoint(
            x: otherFrame.minX + MainWindowController.tabStripLeadingInset + 10,
            y: otherFrame.maxY - TabBarView.height / 2
        )
        bench.source.tabBar(bench.source.tabStrip, tearOff: 1,
                            grabOffset: NSPoint(x: 20, y: 12), screenPoint: drop)
        bench.source.tabBarDragMoved(bench.source.tabStrip, to: drop)
        XCTAssertEqual(other.tabStrip.dropCaretSlotForTesting, 0,
                       "the strip under the pointer shows where the tab would land")

        bench.source.tabBarDragEnded(bench.source.tabStrip, committed: true, at: drop)

        XCTAssertNil(other.tabStrip.dropCaretSlotForTesting, "the caret goes with the drop")
        XCTAssertEqual(other.openNotes.map(\.text), ["beta", ""], "docked at the slot it was over")
        XCTAssertEqual(other.selectedTabIndex, 0)
        XCTAssertEqual(bench.source.openNotes.map(\.text), ["alpha"])
        XCTAssertEqual(bench.registry.controllers.count, 2, "the window that carried it is gone")
        XCTAssertEqual(try XCTUnwrap(bench.store.load()).windows.map { $0.tabs.count }, [1, 2])
    }

    /// A tab dragged out and dropped straight back onto its own strip lands
    /// there like any other drop — no window is left behind.
    @MainActor
    func testTheCaretClearsWhenThePointerLeavesTheStripAgain() throws {
        let bench = try makeBench()
        bench.source.window?.makeKeyAndOrderFrontOffscreen()
        type("alpha", into: bench.source)
        bench.source.addTab()
        type("beta", into: bench.source)

        let other = bench.registry.newWindow()
        other.windowPresenter = { _ in }
        let otherFrame = NSRect(x: -19_000, y: -19_000, width: 820, height: 560)
        other.window?.setFrame(otherFrame, display: false)
        other.window?.contentView?.layoutSubtreeIfNeeded()
        bench.source.dockTargetFinder = { [weak other] _, _ in other }

        let overStrip = NSPoint(
            x: otherFrame.minX + MainWindowController.tabStripLeadingInset + 10,
            y: otherFrame.maxY - TabBarView.height / 2
        )
        bench.source.tabBar(bench.source.tabStrip, tearOff: 1,
                            grabOffset: NSPoint(x: 20, y: 12), screenPoint: overStrip)
        bench.source.tabBarDragMoved(bench.source.tabStrip, to: overStrip)
        XCTAssertNotNil(other.tabStrip.dropCaretSlotForTesting)

        // Down over the editor: the same window, but not its strip.
        bench.source.tabBarDragMoved(bench.source.tabStrip,
                                     to: NSPoint(x: overStrip.x, y: overStrip.y - 200))
        XCTAssertNil(other.tabStrip.dropCaretSlotForTesting, "the caret only lives over the strip")

        bench.source.tabBarDragEnded(bench.source.tabStrip, committed: true,
                                     at: NSPoint(x: overStrip.x, y: overStrip.y - 200))
        XCTAssertEqual(other.openNotes.map(\.text), [""], "nothing docked")
        XCTAssertEqual(bench.registry.controllers.count, 3, "the torn window stands on its own")
    }

    // MARK: - Helpers

    /// A registry with one window in it, wired the way the app wires them.
    ///
    /// Nothing is ordered on screen by default: AppKit constrains a frame it
    /// is asked to show to the display it would show on, and a torn-off
    /// window's frame is exactly what these tests measure. The two tests
    /// that watch a window come and go ask for `showing`, which parks every
    /// window it orders in well outside every display.
    @MainActor
    private func makeBench(showing: Bool = false) throws
        -> (store: SessionStore, registry: WindowRegistry, source: MainWindowController) {
        _ = NSApplication.shared
        let store = SessionStore(directory: try makeTemporaryDirectory())
        let registry = WindowRegistry(store: store)
        let source = MainWindowController(store: store)
        registry.add(source)
        source.windowPresenter = showing ? { $0.makeKeyAndOrderFrontOffscreen() } : { _ in }
        return (store, registry, source)
    }


    /// Types into the tab in front, which is also what makes it dirty.
    @MainActor
    private func type(_ text: String, into controller: MainWindowController) {
        let textView = controller.editorScrolling.textView
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotaMultiWindowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }
}
