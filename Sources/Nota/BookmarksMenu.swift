import AppKit

/// File › Bookmarks (SPEC Todo 13).
///
/// Built the way `RecentDocumentsMenu` is — by hand, rebuilt every time the
/// submenu opens, so it can never show a bookmark that has just been removed
/// from another window sitting there stale.
///
/// The one item that is *not* rebuilt is the first, the ⇧⌘D toggle: a key
/// equivalent has to be in the menu tree before anybody opens the menu it
/// lives in, so that item is made once, in `init`, and only its title is
/// rewritten. Everything after it is thrown away and re-added.
///
/// Then a separator, one item per bookmark in the order they were added —
/// file name, its kind icon, the full path as the tooltip, greyed and inert
/// when the file has gone — a separator, and Remove Missing Bookmarks.
final class BookmarksMenu: NSObject, NSMenuDelegate {
    private let bookmarks: Bookmarks
    /// Whether the tab in front is bookmarked, and whether there is a tab to
    /// bookmark at all: the toggle's title and whether it is offered.
    private let frontTabState: () -> (canBookmark: Bool, isBookmarked: Bool)
    private let onToggleFrontTab: () -> Void
    private let onOpen: (String) -> Void

    /// ⇧⌘D. ⌘D is Duplicate Line, and the editor keeps it.
    private lazy var toggleItem: NSMenuItem = {
        let item = NSMenuItem(
            title: "Bookmark", action: #selector(toggleFrontTab(_:)), keyEquivalent: "d"
        )
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = self
        return item
    }()

    init(
        bookmarks: Bookmarks,
        frontTabState: @escaping () -> (canBookmark: Bool, isBookmarked: Bool),
        onToggleFrontTab: @escaping () -> Void,
        onOpen: @escaping (String) -> Void
    ) {
        self.bookmarks = bookmarks
        self.frontTabState = frontTabState
        self.onToggleFrontTab = onToggleFrontTab
        self.onOpen = onOpen
    }

    /// The submenu, with the toggle already in it — so ⇧⌘D works before the
    /// menu has ever been opened.
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Bookmarks")
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(toggleItem)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.autoenablesItems = false
        while menu.numberOfItems > 1 { menu.removeItem(at: 1) }

        let state = frontTabState()
        toggleItem.title = state.isBookmarked ? "Remove Bookmark" : "Bookmark"
        toggleItem.isEnabled = state.canBookmark

        if !bookmarks.isEmpty {
            menu.addItem(.separator())
            for path in bookmarks.paths {
                menu.addItem(entry(for: path))
            }
        }

        menu.addItem(.separator())
        let clean = NSMenuItem(
            title: "Remove Missing Bookmarks",
            action: #selector(removeMissing(_:)), keyEquivalent: ""
        )
        clean.target = self
        clean.isEnabled = bookmarks.hasMissing
        menu.addItem(clean)
    }

    private func entry(for path: String) -> NSMenuItem {
        let name = Bookmarks.name(of: path)
        let item = NSMenuItem(
            title: name, action: #selector(openBookmark(_:)), keyEquivalent: ""
        )
        item.target = self
        item.representedObject = path
        item.toolTip = path
        item.image = NSImage(
            systemSymbolName: FileKindIcon.symbolName(forTitle: name),
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        // A bookmark whose file has gone stays in the list, greyed out, until
        // it is removed — the volume it lives on may simply not be mounted.
        item.isEnabled = !bookmarks.isMissing(path)
        return item
    }

    @objc private func toggleFrontTab(_ sender: Any?) {
        onToggleFrontTab()
    }

    @objc private func openBookmark(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onOpen(path)
    }

    @objc private func removeMissing(_ sender: Any?) {
        bookmarks.removeMissing()
    }

    /// The toggle is reachable by ⇧⌘D without the menu ever opening, so its
    /// title is written here as well as in `menuNeedsUpdate`.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem === toggleItem else { return menuItem.isEnabled }
        let state = frontTabState()
        menuItem.title = state.isBookmarked ? "Remove Bookmark" : "Bookmark"
        return state.canBookmark
    }
}
