import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store: SessionStore
    private var windowController: MainWindowController?
    private let hotKey = GlobalHotKey()

    /// The settings are carried over from the app's old bundle identifier
    /// before anything can read one, and the session store then carries over
    /// the old support directory as it resolves it.
    override init() {
        Preferences.migrateFromJotIfNeeded()
        store = SessionStore()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let controller = MainWindowController(store: store)
        windowController = controller
        controller.showWindow(nil)
        controller.focusEditor()
        NSApp.activate(ignoringOtherApps: true)

        registerHotKey()
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: Preferences.didChange, object: nil
        )
    }

    @objc private func preferencesChanged() {
        registerHotKey()
    }

    /// Whether the last registration attempt failed — Settings shows a
    /// warning when it did, since the usual cause is another app owning the
    /// same combination.
    var hotKeyRegistrationFailed: Bool { hotKey.registrationFailed }

    private func registerHotKey() {
        guard let shortcut = Preferences.shared.hotKey else {
            hotKey.unregister()
            return
        }
        hotKey.register(shortcut) { [weak self] in self?.toggleSummon() }
    }

    /// Frontmost and visible: get out of the way. Otherwise: come forward.
    private func toggleSummon() {
        let window = windowController?.window
        let isFrontmost = NSApp.isActive && (window?.isVisible ?? false)

        if isFrontmost {
            window?.orderOut(nil)
            if NSApp.windows.contains(where: { $0.isVisible && $0 !== window }) == false {
                NSApp.hide(nil)
            }
        } else {
            showWindow()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// The window is a view onto the cache, not the app itself: closing it
    /// just hides it, and the app stays alive so reopening is instant.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.flushAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        showWindow()
        for url in urls { windowController?.open(url: url) }
    }

    private func showWindow() {
        windowController?.showWindow(nil)
        windowController?.focusEditor()
    }

    // MARK: - Actions

    @objc private func newTab(_ sender: Any?) {
        showWindow()
        windowController?.newTab()
    }

    /// ⌘N: bring the window back if it is hidden, otherwise act like ⌘T.
    @objc private func newWindowOrTab(_ sender: Any?) {
        if windowController?.window?.isVisible == true {
            windowController?.newTab()
        }
        showWindow()
    }

    /// ⌘W closes whichever window is in front — the Settings window when it
    /// is key, otherwise the current tab.
    @objc private func closeTab(_ sender: Any?) {
        if let key = NSApp.keyWindow, key is SettingsWindow {
            key.close()
            return
        }
        windowController?.closeCurrentTab()
    }

    @objc private func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc private func searchAllNotes(_ sender: Any?) {
        windowController?.beginSearchAllNotes()
    }

    @objc private func showTabPicker(_ sender: Any?) {
        windowController?.showTabPicker()
    }

    @objc private func toggleImageSidebar(_ sender: Any?) {
        windowController?.toggleImageSidebar()
    }

    @objc private func toggleZenMode(_ sender: Any?) {
        windowController?.toggleZenMode()
    }

    @objc private func toggleMarkdownPreview(_ sender: Any?) {
        windowController?.toggleMarkdownPreview()
    }

    @objc private func toggleReadingMode(_ sender: Any?) {
        windowController?.toggleReadingMode()
    }

    /// The sidebar item is a verb, so its title flips with the state.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleImageSidebar(_:)) {
            let showing = windowController?.isImageSidebarVisible ?? false
            menuItem.title = showing ? "Hide Images" : "Show Images"
        }
        if menuItem.action == #selector(toggleZenMode(_:)) {
            let zen = windowController?.isZenMode ?? false
            menuItem.title = zen ? "Exit Zen Mode" : "Zen Mode"
        }
        // The preview is a place, not a verb: the titles stay put and the
        // checkmarks say which mode the tab in front is in. ⇧⌘P cycles
        // through both places, so its mark is on in either of them. Neither
        // item is offered on a tab that has no render to show.
        let mode = windowController?.previewMode ?? .off
        if menuItem.action == #selector(toggleMarkdownPreview(_:)) {
            menuItem.state = mode == .off ? .off : .on
            return windowController?.canShowMarkdownPreview ?? false
        }
        if menuItem.action == #selector(toggleReadingMode(_:)) {
            menuItem.state = mode == .reading ? .on : .off
            return windowController?.canShowMarkdownPreview ?? false
        }
        // A PDF tab is a view of a file Nota never writes to, so there is
        // nothing for either save item to do there.
        if menuItem.action == #selector(saveNote(_:))
            || menuItem.action == #selector(saveNoteAs(_:)) {
            return windowController?.currentTabIsSavable ?? true
        }
        return true
    }

    @objc private func saveNote(_ sender: Any?) {
        windowController?.saveCurrent(forcePanel: false)
    }

    @objc private func saveNoteAs(_ sender: Any?) {
        windowController?.saveCurrent(forcePanel: true)
    }

    @objc private func openNote(_ sender: Any?) {
        showWindow()
        windowController?.openFiles()
    }

    @objc private func selectTab(_ sender: NSMenuItem) {
        windowController?.selectTab(at: sender.tag)
    }

    @objc private func selectNextTab(_ sender: Any?) {
        windowController?.selectNextTab()
    }

    @objc private func selectPreviousTab(_ sender: Any?) {
        windowController?.selectPreviousTab()
    }

    @objc private func increaseFontSize(_ sender: Any?) {
        guard let controller = windowController else { return }
        controller.setFontSize(controller.currentFontSize + 1)
    }

    @objc private func decreaseFontSize(_ sender: Any?) {
        guard let controller = windowController else { return }
        controller.setFontSize(controller.currentFontSize - 1)
    }

    @objc private func resetFontSize(_ sender: Any?) {
        windowController?.setFontSize(13)
    }

    // MARK: - Menu

    private func item(
        _ title: String,
        _ action: Selector?,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        target: AnyObject? = nil,
        tag: Int = 0
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { menuItem.keyEquivalentModifierMask = modifiers }
        menuItem.target = target
        menuItem.tag = tag
        return menuItem
    }

    private func submenu(_ title: String, in mainMenu: NSMenu, _ items: [NSMenuItem]) {
        let holder = NSMenuItem()
        let menu = NSMenu(title: title)
        for item in items { menu.addItem(item) }
        holder.submenu = menu
        mainMenu.addItem(holder)
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        submenu("Nota", in: mainMenu, [
            item("About Nota", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(openSettings(_:)), key: ",", target: self),
            .separator(),
            item("Hide Nota", #selector(NSApplication.hide(_:)), key: "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)),
                 key: "h", modifiers: [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Nota", #selector(NSApplication.terminate(_:)), key: "q"),
        ])

        submenu("File", in: mainMenu, [
            item("New Tab", #selector(newTab(_:)), key: "t", target: self),
            item("New Window", #selector(newWindowOrTab(_:)), key: "n", target: self),
            item("Open…", #selector(openNote(_:)), key: "o", target: self),
            .separator(),
            item("Close Tab", #selector(closeTab(_:)), key: "w", target: self),
            .separator(),
            item("Save", #selector(saveNote(_:)), key: "s", target: self),
            item("Save As…", #selector(saveNoteAs(_:)), key: "s",
                 modifiers: [.command, .shift], target: self),
        ])

        let findMenu = NSMenu(title: "Find")
        let findAction = #selector(NSTextView.performTextFinderAction(_:))
        for entry in [
            ("Find…", "f", NSEvent.ModifierFlags.command, NSTextFinder.Action.showFindInterface),
            ("Find Next", "g", .command, .nextMatch),
            ("Find Previous", "g", [.command, .shift], .previousMatch),
            ("Use Selection for Find", "e", .command, .setSearchString),
        ] as [(String, String, NSEvent.ModifierFlags, NSTextFinder.Action)] {
            findMenu.addItem(item(entry.0, findAction, key: entry.1,
                                  modifiers: entry.2, tag: entry.3.rawValue))
        }
        findMenu.addItem(.separator())
        findMenu.addItem(item("Search All Notes…", #selector(searchAllNotes(_:)),
                              key: "f", modifiers: [.command, .shift], target: self))
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = findMenu

        submenu("Edit", in: mainMenu, [
            item("Undo", Selector(("undo:")), key: "z"),
            item("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), key: "x"),
            item("Copy", #selector(NSText.copy(_:)), key: "c"),
            item("Paste", #selector(NSText.paste(_:)), key: "v"),
            item("Select All", #selector(NSText.selectAll(_:)), key: "a"),
            .separator(),
            findItem,
        ])

        submenu("View", in: mainMenu, [
            item("Increase Font Size", #selector(increaseFontSize(_:)), key: "+", target: self),
            item("Decrease Font Size", #selector(decreaseFontSize(_:)), key: "-", target: self),
            item("Actual Size", #selector(resetFontSize(_:)), key: "0", target: self),
            .separator(),
            item("Show Images", #selector(toggleImageSidebar(_:)), key: "b", target: self),
            item("Markdown Preview", #selector(toggleMarkdownPreview(_:)), key: "p",
                 modifiers: [.command, .shift], target: self),
            item("Reading Mode", #selector(toggleReadingMode(_:)), key: "p",
                 modifiers: [.command, .shift, .option], target: self),
            item("Zen Mode", #selector(toggleZenMode(_:)), key: "z",
                 modifiers: [.command, .option], target: self),
        ])

        var windowItems: [NSMenuItem] = [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Go to Tab…", #selector(showTabPicker(_:)), key: "p", target: self),
            .separator(),
            item("Next Tab", #selector(selectNextTab(_:)), key: "\t",
                 modifiers: [.control], target: self),
            item("Previous Tab", #selector(selectPreviousTab(_:)), key: "\t",
                 modifiers: [.control, .shift], target: self),
            .separator(),
        ]
        for number in 1...9 {
            windowItems.append(item("Tab \(number)", #selector(selectTab(_:)),
                                    key: "\(number)", target: self, tag: number - 1))
        }
        submenu("Window", in: mainMenu, windowItems)

        NSApp.mainMenu = mainMenu
    }
}
