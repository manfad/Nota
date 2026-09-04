import AppKit

/// File › Open Recent.
///
/// `NSDocumentController` already keeps the list — `noteNewRecentDocumentURL`
/// is the only thing a file open has to call — so this is only the menu on
/// top of it, built by hand rather than through a nib's automatic binding.
/// Rebuilt every time the submenu opens (`menuNeedsUpdate`), so it can never
/// show a document from an earlier launch, or one `clearRecentDocuments` just
/// dropped, sitting there stale.
///
/// Most recent first — `recentDocumentURLs`' own order — a separator, then
/// Clear Menu.
final class RecentDocumentsMenu: NSObject, NSMenuDelegate {
    /// What choosing an item does. The window it opens in is the caller's
    /// business, the same as `application(_:open:)`.
    private let onSelect: (URL) -> Void

    init(onSelect: @escaping (URL) -> Void) {
        self.onSelect = onSelect
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        for url in urls {
            let entry = NSMenuItem(
                title: url.lastPathComponent,
                action: #selector(chooseRecentDocument(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = url
            entry.toolTip = url.path
            menu.addItem(entry)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }

        let clear = NSMenuItem(
            title: "Clear Menu", action: #selector(clearRecentDocuments(_:)), keyEquivalent: ""
        )
        clear.target = self
        clear.isEnabled = !urls.isEmpty
        menu.addItem(clear)
    }

    @objc private func chooseRecentDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onSelect(url)
    }

    @objc private func clearRecentDocuments(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}
