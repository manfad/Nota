import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store: SessionStore
    /// Every open window. The app itself keeps no single one: menu actions
    /// and the summon key all mean whichever window is in front.
    private let windows: WindowRegistry
    private let hotKey = GlobalHotKey()
    /// File › Open Recent. `NSMenu.delegate` is weak, so this is what keeps
    /// it alive for as long as the app is.
    private lazy var recentDocumentsMenu = RecentDocumentsMenu { [weak self] url in
        self?.openRecentDocument(url)
    }

    /// The window every action means — nil only before the first one exists.
    private var activeController: MainWindowController? { windows.activeController }

    /// The settings are carried over from the app's old bundle identifier
    /// before anything can read one, and the session store then carries over
    /// the old support directory as it resolves it.
    override init() {
        Preferences.migrateFromJotIfNeeded()
        let store = SessionStore()
        self.store = store
        self.windows = WindowRegistry(store: store)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        restoreWindows()
        showWindow()
        NSApp.activate(ignoringOtherApps: true)

        registerHotKey()
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: Preferences.didChange, object: nil
        )
    }

    /// One window per window in the session file, in the order it holds
    /// them — one empty window when there is no session yet. Nothing is
    /// saved while they are being built: each window flushes as it restores,
    /// and the file being read is still the only copy of the rest.
    private func restoreWindows() {
        let state = store.load()
        if let size = state?.fontSize { Preferences.shared.fontSize = CGFloat(size) }
        windows.isRestoring = true
        for sessionWindow in state?.windows ?? [] {
            windows.restoreWindow(sessionWindow)
        }
        windows.isRestoring = false
        if windows.controllers.isEmpty { windows.newWindow() }
        // Only now that every window is open is a cache file with no tab
        // behind it really rubbish.
        windows.pruneCache()
        windows.saveSession()
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
        let window = activeController?.window
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
        windows.flushAll()
        windows.drainCacheWrites()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        showWindow()
        for url in urls { activeController?.open(url: url) }
    }

    /// Brings the window in front forward, opening one if the app has none
    /// — every action that needs a window goes through here first.
    @discardableResult
    private func showWindow() -> MainWindowController {
        let controller = windows.activeController ?? windows.newWindow()
        controller.showWindow(nil)
        controller.focusEditor()
        return controller
    }

    /// A second window, cascaded off the one in front, with one untitled tab.
    @discardableResult
    func newWindow(with note: Note? = nil, frame: NSRect? = nil) -> MainWindowController {
        let controller = note.map { windows.newWindow(with: $0, frame: frame) }
            ?? windows.newWindow(frame: frame)
        controller.showWindow(nil)
        controller.focusEditor()
        return controller
    }

    func removeWindow(_ controller: MainWindowController) {
        windows.removeWindow(controller)
    }

    // MARK: - Actions

    @objc private func newTab(_ sender: Any?) {
        showWindow()
        activeController?.newTab()
    }

    /// ⌘N: bring the window back if it is hidden, otherwise act like ⌘T.
    @objc private func newWindowOrTab(_ sender: Any?) {
        if activeController?.window?.isVisible == true {
            activeController?.newTab()
        }
        showWindow()
    }

    /// ⇧⌘N: a window of its own, with one untitled tab.
    @objc private func newWindowItem(_ sender: Any?) {
        newWindow()
    }

    /// ⌘W closes whichever window is in front — the Settings window when it
    /// is key, otherwise the current tab.
    @objc private func closeTab(_ sender: Any?) {
        if let key = NSApp.keyWindow, key is SettingsWindow {
            key.close()
            return
        }
        activeController?.closeCurrentTab()
    }

    @objc private func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc private func searchAllNotes(_ sender: Any?) {
        activeController?.beginSearchAllNotes()
    }

    @objc private func showTabPicker(_ sender: Any?) {
        activeController?.showTabPicker()
    }

    @objc private func toggleImageSidebar(_ sender: Any?) {
        activeController?.toggleImageSidebar()
    }

    @objc private func toggleZenMode(_ sender: Any?) {
        activeController?.toggleZenMode()
    }

    @objc private func toggleMarkdownPreview(_ sender: Any?) {
        activeController?.toggleMarkdownPreview()
    }

    @objc private func toggleReadingMode(_ sender: Any?) {
        activeController?.toggleReadingMode()
    }

    @objc private func goToLine(_ sender: Any?) {
        activeController?.showGoToLine()
    }

    /// The sidebar item is a verb, so its title flips with the state.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleImageSidebar(_:)) {
            let showing = activeController?.isImageSidebarVisible ?? false
            menuItem.title = showing ? "Hide Images" : "Show Images"
        }
        if menuItem.action == #selector(toggleZenMode(_:)) {
            let zen = activeController?.isZenMode ?? false
            menuItem.title = zen ? "Exit Zen Mode" : "Zen Mode"
        }
        // The preview is a place, not a verb: the titles stay put and the
        // checkmarks say which mode the tab in front is in. ⇧⌘P cycles
        // through both places, so its mark is on in either of them. Neither
        // item is offered on a tab that has no render to show.
        let mode = activeController?.previewMode ?? .off
        if menuItem.action == #selector(toggleMarkdownPreview(_:)) {
            menuItem.state = mode == .off ? .off : .on
            menuItem.title = RenderedPreviewKind.previewMenuTitle(
                activeController?.currentRenderedPreviewKind
            )
            return activeController?.canShowRenderedPreview ?? false
        }
        if menuItem.action == #selector(toggleReadingMode(_:)) {
            menuItem.state = mode == .reading ? .on : .off
            return activeController?.canShowRenderedPreview ?? false
        }
        // The three size keys are one pair of hands doing two jobs, and the
        // window in front is what knows which. "Actual Size" is the name of
        // both jobs, and stays put.
        if menuItem.action == #selector(zoomIn(_:))
            || menuItem.action == #selector(zoomOut(_:)) {
            let titles = activeController?.sizeMenuTitles
                ?? (increase: "Increase Font Size", decrease: "Decrease Font Size")
            menuItem.title = menuItem.action == #selector(zoomIn(_:))
                ? titles.increase : titles.decrease
        }
        // Reading mode has no editor on screen to jump about in, and a PDF or
        // a picture has no lines to jump to.
        if menuItem.action == #selector(goToLine(_:)) {
            return activeController?.canGoToLine ?? false
        }
        // A PDF tab is a view of a file Nota never writes to, so there is
        // nothing for either save item to do there.
        if menuItem.action == #selector(saveNote(_:))
            || menuItem.action == #selector(saveNoteAs(_:)) {
            return activeController?.currentTabIsSavable ?? true
        }
        return true
    }

    @objc private func saveNote(_ sender: Any?) {
        activeController?.saveCurrent(forcePanel: false)
    }

    @objc private func saveNoteAs(_ sender: Any?) {
        activeController?.saveCurrent(forcePanel: true)
    }

    @objc private func openNote(_ sender: Any?) {
        showWindow()
        activeController?.openFiles()
    }

    /// Choosing a File › Open Recent item — the same funnel Finder's own
    /// "Open With" and a drag onto the Dock icon use.
    private func openRecentDocument(_ url: URL) {
        showWindow()
        activeController?.open(url: url)
    }

    @objc private func selectTab(_ sender: NSMenuItem) {
        activeController?.selectTab(at: sender.tag)
    }

    @objc private func selectNextTab(_ sender: Any?) {
        activeController?.selectNextTab()
    }

    @objc private func selectPreviousTab(_ sender: Any?) {
        activeController?.selectPreviousTab()
    }

    /// ⌘+, ⌘- and ⌘0. What the three mean is the window's business — the
    /// editor's font size where there is an editor on screen, and the
    /// content's zoom where the content is all there is — so all three ask
    /// and none of them decides.
    @objc private func zoomIn(_ sender: Any?) {
        activeController?.zoomIn()
    }

    @objc private func zoomOut(_ sender: Any?) {
        activeController?.zoomOut()
    }

    @objc private func actualSize(_ sender: Any?) {
        activeController?.actualSize()
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

    /// The Notepad++ line hands. Every one is nil-targeted, like Cut and
    /// Paste and the find items: the key arrives at whatever view has the
    /// keyboard, which is the editor and nothing else — `NotaTextView` is the
    /// only thing in the app that answers to these selectors, so all seven
    /// grey out over a rendered page, a PDF, a picture and the find field,
    /// and in every vim mode but insert.
    private var lineOperationItems: [NSMenuItem] {
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        return [
            item("Move Line Up", #selector(NotaTextView.moveLinesUp(_:)),
                 key: up, modifiers: [.option]),
            item("Move Line Down", #selector(NotaTextView.moveLinesDown(_:)),
                 key: down, modifiers: [.option]),
            item("Duplicate Lines", #selector(NotaTextView.duplicateLines(_:)),
                 key: down, modifiers: [.option, .shift]),
            // The title of this one is written as it is validated: duplicate
            // with nothing in hand, select the next occurrence with something.
            item("Duplicate Line", #selector(NotaTextView.duplicateOrSelectNext(_:)), key: "d"),
            .separator(),
            item("Toggle Comment", #selector(NotaTextView.toggleLineComment(_:)), key: "/"),
            item("Indent", #selector(NotaTextView.indentLines(_:)), key: "]"),
            item("Outdent", #selector(NotaTextView.outdentLines(_:)), key: "["),
        ]
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

        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = recentDocumentsMenu
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu

        submenu("File", in: mainMenu, [
            item("New Tab", #selector(newTab(_:)), key: "t", target: self),
            // ⌘N is Nota's older new-tab key, and also what brings a hidden
            // window back; ⇧⌘N is the window itself.
            item("New Tab", #selector(newWindowOrTab(_:)), key: "n", target: self),
            item("New Window", #selector(newWindowItem(_:)), key: "n",
                 modifiers: [.command, .shift], target: self),
            item("Open…", #selector(openNote(_:)), key: "o", target: self),
            recentItem,
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
            ("Find and Replace…", "f", [.command, .option], .showReplaceInterface),
            ("Find Next", "g", .command, .nextMatch),
            ("Find Previous", "g", [.command, .shift], .previousMatch),
            ("Use Selection for Find", "e", .command, .setSearchString),
        ] as [(String, String, NSEvent.ModifierFlags, NSTextFinder.Action)] {
            findMenu.addItem(item(entry.0, findAction, key: entry.1,
                                  modifiers: entry.2, tag: entry.3.rawValue))
        }
        findMenu.addItem(item("Go to Line…", #selector(goToLine(_:)), key: "l", target: self))
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
        ] + lineOperationItems + [
            .separator(),
            findItem,
        ])

        submenu("View", in: mainMenu, [
            item("Increase Font Size", #selector(zoomIn(_:)), key: "+", target: self),
            item("Decrease Font Size", #selector(zoomOut(_:)), key: "-", target: self),
            item("Actual Size", #selector(actualSize(_:)), key: "0", target: self),
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
