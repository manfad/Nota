import AppKit
import Foundation
import XCTest
@testable import Nota

/// The adjustable app shortcuts: the table itself, the menu reading from it,
/// and the Settings tab that edits it.
final class ShortcutsTests: AppKitTestCase {
    private var temporaryDirectories: [URL] = []
    private var storedShortcuts: [ShortcutAction: KeyCombo] = [:]

    /// Half these tests write the one shared table, and a failure part-way
    /// through one must not leave the next reading somebody else's override —
    /// so the snapshot is taken and put back around every test, not inside it.
    override func setUpWithError() throws {
        storedShortcuts = Preferences.shared.shortcuts
        Preferences.shared.shortcuts = [:]
    }

    override func tearDownWithError() throws {
        Preferences.shared.shortcuts = storedShortcuts
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    // MARK: - The table

    /// The menu is the truth: every default has to be the key the item was
    /// built with before the table existed.
    @MainActor
    func testEveryDefaultIsTheKeyItsMenuItemCarries() throws {
        let delegate = try makeDelegate()
        delegate.buildMenu()
        let items = allItems(in: try XCTUnwrap(NSApp.mainMenu))

        for action in ShortcutAction.allCases {
            // Bookmark This Tab is the bookmarks submenu's toggle, whose title
            // flips with the state, so it is matched on its key instead.
            let title = action == .bookmarkTab ? "Bookmark" : action.titleKey
            let matches = items.filter { $0.title == title }
            XCTAssertFalse(matches.isEmpty, "no menu item titled \(title)")
            let combo = action.defaultCombo
            XCTAssertTrue(
                matches.contains {
                    $0.keyEquivalent == combo.key && $0.keyEquivalentModifierMask == combo.flags
                },
                "\(title) defaults to \(combo.displayName), menu has "
                    + matches.map { "\($0.keyEquivalent) \($0.keyEquivalentModifierMask.rawValue)" }
                        .joined(separator: ", ")
            )
        }
    }

    func testACombosNameReadsTheWayTheMenuBarDrawsIt() {
        XCTAssertEqual(KeyCombo("p", [.command, .shift]).displayName, "⇧⌘P")
        XCTAssertEqual(KeyCombo("p", [.command, .shift, .option]).displayName, "⌥⇧⌘P")
        XCTAssertEqual(KeyCombo("\t", [.control]).displayName, "⌃Tab")
        XCTAssertEqual(KeyCombo("\t", [.control, .shift]).displayName, "⌃⇧Tab")
        XCTAssertEqual(KeyCombo("/").displayName, "⌘/")
        XCTAssertEqual(KeyCombo(",").displayName, "⌘,")
        XCTAssertEqual(KeyCombo(" ", [.option]).displayName, "⌥Space")
        XCTAssertEqual(
            KeyCombo(String(UnicodeScalar(NSUpArrowFunctionKey)!), [.option]).displayName, "⌥↑"
        )
    }

    /// ⌘ or ⌃ has to be in it, and Tab is read off the key code because it has
    /// no character worth storing.
    func testRecordingKeepsOnlyCombinationsAnAppShortcutMayHave() throws {
        XCTAssertEqual(KeyCombo.recorded(from: keyEvent("j", [.command])), KeyCombo("j"))
        XCTAssertEqual(
            KeyCombo.recorded(from: keyEvent("J", [.command, .shift])),
            KeyCombo("j", [.command, .shift]),
            "a letter is stored lowercase with ⇧ beside it, the way a menu item spells it"
        )
        XCTAssertEqual(
            KeyCombo.recorded(from: keyEvent("\t", [.control], keyCode: 48)),
            KeyCombo("\t", [.control])
        )
        XCTAssertNil(KeyCombo.recorded(from: keyEvent("j", [.option])),
                     "⌥J is ordinary typing, not a shortcut")
        XCTAssertNil(KeyCombo.recorded(from: keyEvent("j", [])))
    }

    func testAnOverrideRoundTripsThroughPreferences() throws {
        let suite = "nota.shortcuts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)

        XCTAssertEqual(preferences.shortcuts, [:], "nothing is stored until something moves")
        XCTAssertEqual(preferences.combo(for: .goToTab), KeyCombo("j", [.command, .shift]))

        preferences.shortcuts = [.goToTab: KeyCombo("j", [.command, .option])]
        XCTAssertEqual(preferences.combo(for: .goToTab), KeyCombo("j", [.command, .option]))
        XCTAssertEqual(preferences.combo(for: .save), KeyCombo("s"),
                       "only the moved key is stored; the rest follow their default")

        // And it survives a fresh reader over the same defaults.
        let reread = Preferences(defaults: defaults)
        XCTAssertEqual(reread.shortcuts, [.goToTab: KeyCombo("j", [.command, .option])])
        XCTAssertEqual(reread.combo(for: .goToTab).displayName, "⌥⌘J")
    }

    // MARK: - The menu

    @MainActor
    func testTheMenuFollowsAChangedShortcut() throws {
        let originalHotKey = Preferences.shared.hotKey
        defer { Preferences.shared.hotKey = originalHotKey }
        // Nothing in a test should be registering a system-wide hotkey, and
        // the notification below goes through the code that would.
        Preferences.shared.hotKey = nil

        let delegate = try makeDelegate()
        delegate.buildMenu()
        let before = try XCTUnwrap(item(titled: "Jump to Tab…"))
        XCTAssertEqual(before.keyEquivalent, "j")
        XCTAssertEqual(before.keyEquivalentModifierMask, [.command, .shift])

        Preferences.shared.shortcuts = [.goToTab: KeyCombo("j", [.command, .option])]
        delegate.perform(Selector(("preferencesChanged")))

        let after = try XCTUnwrap(item(titled: "Jump to Tab…"))
        XCTAssertEqual(after.keyEquivalent, "j")
        XCTAssertEqual(after.keyEquivalentModifierMask, [.command, .option])
        XCTAssertEqual(try XCTUnwrap(item(titled: "Save")).keyEquivalent, "s",
                       "the rest of the menu is unmoved")
    }
    /// The sentence about Summon is not a footnote under the group any more:
    /// it sits behind a `?` after the row's label, and a click on it opens a
    /// popover that says it. The popover is transient, so a click anywhere
    /// else puts it away.
    @MainActor
    func testTheSummonExplanationSitsBehindAHelpButton() throws {
        _ = NSApplication.shared
        let controller = SettingsWindowController.shared
        defer { controller.selectPage(at: 0); controller.window?.orderOut(nil) }
        XCTAssertTrue(controller.selectPage(titled: "Shortcuts"))
        controller.window?.makeKeyAndOrderFrontOffscreen()

        let help = controller.summonHelpForTesting
        let button = try XCTUnwrap(help.button, "a ? follows the Summon label")
        XCTAssertEqual(button.bezelStyle, .helpButton)
        XCTAssertFalse(help.popover.isShown)

        button.performClick(nil)
        XCTAssertTrue(help.popover.isShown, "a click opens the popover")
        XCTAssertEqual(help.popover.behavior, .transient)
        let text = help.popover.contentViewController?.view.subviews
            .compactMap { $0 as? NSTextField }.first?.stringValue
        XCTAssertEqual(text, "Summon brings Nota to the front from any app, even while it is hidden.")
        let size = help.popover.contentSize
        XCTAssertGreaterThan(size.width, 200, "the sentence is laid out wide, not folded to nothing")
        XCTAssertLessThan(size.height, 80, "two or three lines, not a column")
        help.popover.performClose(nil)
    }


    /// The bookmarks toggle is built once and kept, so its key has to be
    /// rewritten on every rebuild rather than only on the first.
    @MainActor
    func testTheBookmarksToggleFollowsAChangedShortcut() throws {
        let bookmarks = BookmarksMenu(
            bookmarks: Bookmarks(), frontTabState: { (true, false) },
            onToggleFrontTab: {}, onOpen: { _ in }
        )
        let menu = bookmarks.makeMenu()
        let first = menu.item(at: 0)
        XCTAssertEqual(first?.keyEquivalent, "d")
        XCTAssertEqual(first?.keyEquivalentModifierMask, [.command])
        // ⇧⌘D is the other half of the pair: the picker, in bookmarks mode.
        XCTAssertEqual(menu.item(at: 1)?.keyEquivalent, "d")
        XCTAssertEqual(menu.item(at: 1)?.keyEquivalentModifierMask, [.command, .shift])

        Preferences.shared.shortcuts = [.bookmarkTab: KeyCombo("d", [.command, .control])]
        let second = bookmarks.makeMenu().item(at: 0)
        XCTAssertEqual(second?.keyEquivalentModifierMask, [.command, .control])
    }

    // MARK: - The Settings page

    @MainActor
    func testSettingsHasEightPagesAndKeepsSummonOnShortcuts() throws {
        _ = NSApplication.shared
        let controller = SettingsWindowController.shared
        let root = try XCTUnwrap(controller.window?.contentView)
        defer { controller.selectPage(at: 0) }

        XCTAssertEqual(
            controller.pageTitles,
            ["General", "Appearance", "Editor", "Tab bar", "Status bar",
             "Shortcuts", "File types", "About"]
        )

        controller.selectPage(at: 0)
        XCTAssertNil(
            descendant(of: root, ofType: ShortcutRecorderField.self) {
                $0.accessibilityLabel() == "Summon"
            },
            "Summon has left General"
        )
        XCTAssertNotNil(descendant(of: root, ofType: NSPopUpButton.self) {
            $0.itemTitles.contains("简体中文")
        }, "General still holds Language")

        XCTAssertTrue(controller.selectPage(titled: "Shortcuts"))
        XCTAssertNotNil(
            descendant(of: root, ofType: ShortcutRecorderField.self) {
                $0.accessibilityLabel() == "Summon"
            },
            "Summon is the first row of Shortcuts"
        )
        XCTAssertEqual(controller.rows(on: 5).first?.title, "Summon")
        for action in [ShortcutAction.goToTab, .showBookmarks, .settings] {
            XCTAssertNotNil(field(for: action, in: root), "no row for \(action.titleKey)")
        }
    }

    /// No Save button holds the key back: the combination is written the
    /// moment it is recorded, and taking it away again empties the table.
    @MainActor
    func testRecordingAComboWritesItAtOnce() throws {
        _ = NSApplication.shared
        let controller = SettingsWindowController.shared
        let root = try XCTUnwrap(controller.window?.contentView)
        controller.selectPage(titled: "Shortcuts")
        defer { controller.selectPage(at: 0) }

        XCTAssertNil(descendant(of: root, ofType: NSButton.self) { $0.title == "Save" },
                     "there is nothing to press")

        let row = try XCTUnwrap(field(for: .goToTab, in: root))
        XCTAssertEqual(row.combo, KeyCombo("j", [.command, .shift]))
        row.recordForTesting(keyEvent("j", [.command, .option]))

        XCTAssertEqual(row.combo, KeyCombo("j", [.command, .option]))
        XCTAssertEqual(Preferences.shared.combo(for: .goToTab), KeyCombo("j", [.command, .option]),
                       "recording a key is what writes it")

        // Delete puts the command's own key back, which is not an override at
        // all, so the table empties again.
        row.recordForTesting(keyEvent("\u{8}", [], keyCode: 51))
        XCTAssertEqual(row.combo, KeyCombo("j", [.command, .shift]))
        XCTAssertEqual(Preferences.shared.shortcuts, [:])
    }

    /// A clash is the one thing live apply refuses: nothing is written, the
    /// field goes back to the key that is stored, and the page says why.
    @MainActor
    func testATakenComboWarnsAndIsNeverWritten() throws {
        _ = NSApplication.shared
        let controller = SettingsWindowController.shared
        let root = try XCTUnwrap(controller.window?.contentView)
        controller.selectPage(titled: "Shortcuts")
        defer { controller.selectPage(at: 0) }

        // The page's own warning line, not Summon's: both are red, so the one
        // the list writes to is picked out by name.
        XCTAssertNotNil(descendant(of: root, ofType: NSButton.self) {
            $0.title == "Reset to Defaults"
        }, "Reset to Defaults is on the page")
        let warning = try XCTUnwrap(descendant(of: root, ofType: NSTextField.self) {
            $0.accessibilityIdentifier() == "shortcut-conflict"
        })
        XCTAssertTrue(warning.isHidden, "nothing is wrong with the shipped table")
        let row = try XCTUnwrap(field(for: .openFile, in: root))

        // ⌘S is Save's, and two commands on one key leaves one unreachable.
        row.recordForTesting(keyEvent("s", [.command]))
        XCTAssertFalse(warning.isHidden)
        XCTAssertTrue(warning.stringValue.contains("Save"))
        XCTAssertTrue(warning.stringValue.contains("Open…"))
        XCTAssertTrue(warning.stringValue.contains("⌘S"))
        XCTAssertEqual(Preferences.shared.shortcuts, [:], "a clash is never written")
        XCTAssertEqual(row.combo, ShortcutAction.openFile.defaultCombo,
                       "the field goes back to the key that is stored")

        // ⌘C belongs to the Mac, not to Nota.
        row.recordForTesting(keyEvent("c", [.command]))
        XCTAssertFalse(warning.isHidden)
        XCTAssertTrue(warning.stringValue.contains("Copy"))
        XCTAssertEqual(Preferences.shared.shortcuts, [:])
        XCTAssertEqual(row.combo, ShortcutAction.openFile.defaultCombo)

        // Somewhere free, and it lands at once — and clears the warning.
        row.recordForTesting(keyEvent("j", [.command, .control]))
        XCTAssertTrue(warning.isHidden)
        XCTAssertEqual(Preferences.shared.combo(for: .openFile), KeyCombo("j", [.command, .control]))
    }

    @MainActor
    func testResetToDefaultsClearsEveryOverrideAtOnce() throws {
        _ = NSApplication.shared
        Preferences.shared.shortcuts = [
            .goToTab: KeyCombo("j", [.command, .option]),
            .zenMode: KeyCombo("y", [.command, .control]),
        ]

        let controller = SettingsWindowController.shared
        let root = try XCTUnwrap(controller.window?.contentView)
        controller.selectPage(titled: "Shortcuts")
        defer { controller.selectPage(at: 0) }

        let row = try XCTUnwrap(field(for: .goToTab, in: root))
        XCTAssertEqual(row.combo, KeyCombo("j", [.command, .option]),
                       "the tab opens showing what is stored")

        let reset = try XCTUnwrap(descendant(of: root, ofType: NSButton.self) {
            $0.title == "Reset to Defaults"
        })
        reset.performClick(nil)
        XCTAssertEqual(row.combo, KeyCombo("j", [.command, .shift]))
        XCTAssertEqual(Preferences.shared.shortcuts, [:], "the table empties on the press")
        XCTAssertEqual(Preferences.shared.combo(for: .zenMode), KeyCombo("z", [.command, .option]))
    }

    // MARK: - Helpers

    @MainActor
    private func makeDelegate() throws -> AppDelegate {
        _ = NSApplication.shared
        return AppDelegate(store: SessionStore(directory: try makeTemporaryDirectory()))
    }

    private func keyEvent(
        _ characters: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16 = 0
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!
    }

    @MainActor
    private func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allItems) ?? [])
        }
    }

    @MainActor
    private func item(titled title: String) -> NSMenuItem? {
        guard let main = NSApp.mainMenu else { return nil }
        return allItems(in: main).first { $0.title == title }
    }

    @MainActor
    private func field(for action: ShortcutAction, in root: NSView) -> ShortcutRecorderField? {
        descendant(of: root, ofType: ShortcutRecorderField.self) {
            $0.accessibilityLabel() == action.title
        }
    }

    private func descendant<T: NSView>(
        of view: NSView, ofType type: T.Type, where matches: (T) -> Bool = { _ in true }
    ) -> T? {
        if let match = view as? T, matches(match) { return match }
        for subview in view.subviews {
            if let found = descendant(of: subview, ofType: type, where: matches) { return found }
        }
        return nil
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nota-shortcuts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}
