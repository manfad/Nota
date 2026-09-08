import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store: SessionStore
    /// Every open window. The app itself keeps no single one: menu actions
    /// and the summon key all mean whichever window is in front.
    private let windows: WindowRegistry
    private let hotKey = GlobalHotKey()
    private var installedLanguage: AppLanguage?
    /// The shortcut table the menu was built from. A changed key has to
    /// rebuild the menu, and only a comparison can tell that it changed.
    private var installedShortcuts: [ShortcutAction: KeyCombo] = [:]
    /// File › Open Recent. `NSMenu.delegate` is weak, so this is what keeps
    /// it alive for as long as the app is.
    private lazy var recentDocumentsMenu = RecentDocumentsMenu { [weak self] url in
        self?.openRecentDocument(url)
    }
    /// File › Bookmarks. Kept alive here for the same reason — `NSMenu`'s
    /// delegate is weak — and handed the one bookmark list the app has.
    private lazy var bookmarksMenu = BookmarksMenu(
        bookmarks: windows.bookmarks,
        frontTabState: { [weak self] in
            (self?.activeController?.canBookmarkCurrentTab ?? false,
             self?.activeController?.currentTabIsBookmarked ?? false)
        },
        onToggleFrontTab: { [weak self] in
            self?.activeController?.toggleBookmarkForCurrentTab()
        },
        onShowAll: { [weak self] in
            self?.showWindow()
            self?.activeController?.showBookmarksPicker()
        },
        onOpen: { [weak self] path in
            self?.showWindow()
            self?.activeController?.openBookmark(path: path)
        }
    )

    /// The window every action means — nil only before the first one exists.
    private var activeController: MainWindowController? { windows.activeController }

    /// The settings are carried over from the app's old bundle identifier
    /// before anything can read one, and the session store then carries over
    /// the old support directory as it resolves it.
    ///
    /// The store is only ever passed by tests, so a menu can be built against
    /// a scratch directory rather than the session you are actually working in.
    init(store: SessionStore? = nil) {
        Preferences.migrateFromJotIfNeeded()
        let store = store ?? SessionStore()
        self.store = store
        self.windows = WindowRegistry(store: store)
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        LaunchTiming.mark("will finish launching")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTiming.mark("did finish launching")
        // Before the first window is made, so nothing flashes the other
        // appearance on launch. From then on the setting applies itself.
        Preferences.shared.theme.apply()
        LaunchTiming.mark("theme applied")
        // Before the menu, since File › Export… and File › Print… ask what
        // the tab in front can be exported to and a target with no hook is
        // not offered. Five closures and no work, so it costs the launch
        // nothing.
        Exporter.installDefaultHooks()
        buildMenu()
        LaunchTiming.mark("menu built")
        restoreWindows()
        showWindow()
        LaunchTiming.mark("window shown")
        NSApp.activate(ignoringOtherApps: true)

        registerHotKey()
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: Preferences.didChange, object: nil
        )
        LaunchTiming.mark("hotkey registered")
        LaunchTiming.scheduleReport()
    }

    /// One window per window in the session file, in the order it holds
    /// them — one empty window when there is no session yet. Nothing is
    /// saved while they are being built: each window flushes as it restores,
    /// and the file being read is still the only copy of the rest.
    private func restoreWindows() {
        let state = store.load()
        LaunchTiming.mark("session file read")
        if let size = state?.fontSize { Preferences.shared.fontSize = CGFloat(size) }
        windows.bookmarks.replace(with: state?.bookmarks ?? [])
        windows.isRestoring = true
        for sessionWindow in state?.windows ?? [] {
            windows.restoreWindow(sessionWindow)
        }
        windows.isRestoring = false
        if windows.controllers.isEmpty { windows.newWindow() }
        // Only now that every window is open is a cache file with no tab
        // behind it really rubbish.
        LaunchTiming.mark("windows restored")
        windows.pruneCache()
        windows.saveSession()
        LaunchTiming.mark("cache pruned, session saved")
    }

    @objc private func preferencesChanged() {
        registerHotKey()
        if installedLanguage != Preferences.shared.language
            || installedShortcuts != Preferences.shared.shortcuts {
            buildMenu()
        }
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
            // One name, ticked while the column is up, rather than a title
            // that flips between Show and Hide. The name is what the column
            // is listing: a note's pictures, a book's chapters, or a
            // document's pages. ⌘B and the tick are the same in all three.
            menuItem.title = L10n.text(
                activeController?.sidebarListTitle ?? "Image Gallery"
            )
            menuItem.state = showing ? .on : .off
        }
        if menuItem.action == #selector(toggleZenMode(_:)) {
            let zen = activeController?.isZenMode ?? false
            menuItem.title = L10n.text(zen ? "Exit Zen Mode" : "Zen Mode")
        }
        // The preview is a place, not a verb: the titles stay put and the
        // checkmarks say which mode the tab in front is in. ⌘P cycles
        // through both places, so its mark is on in either of them. Neither
        // item is offered on a tab that has no render to show.
        let mode = activeController?.previewMode ?? .off
        if menuItem.action == #selector(toggleMarkdownPreview(_:)) {
            menuItem.state = mode == .off ? .off : .on
            menuItem.title = L10n.text(RenderedPreviewKind.previewMenuTitle(
                activeController?.currentRenderedPreviewKind
            ))
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
            menuItem.title = L10n.text(menuItem.action == #selector(zoomIn(_:))
                ? titles.increase : titles.decrease)
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
        if menuItem.action == #selector(printNote(_:)) {
            // Only a tab that makes a PDF prints: a grid's rows and a book
            // are files, not pages.
            return activeController?.canPrintCurrentTab ?? false
        }
        if menuItem.action == #selector(exportNote(_:)) {
            // Every tab exports as something; only an empty window has
            // nothing to offer.
            return activeController?.canExportCurrentTab ?? false
        }
        if menuItem.action == #selector(revealInFinder(_:)) {
            return activeController?.currentTabHasFile ?? false
        }
        return true
    }

    @objc private func saveNote(_ sender: Any?) {
        activeController?.saveCurrent(forcePanel: false)
    }

    @objc private func revealInFinder(_ sender: Any?) {
        activeController?.revealCurrentTabInFinder()
    }

    @objc private func saveNoteAs(_ sender: Any?) {
        activeController?.saveCurrent(forcePanel: true)
    }

    @objc private func exportNote(_ sender: Any?) {
        activeController?.exportCurrentTab()
    }

    @objc private func printNote(_ sender: Any?) {
        activeController?.printCurrentTab()
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
        let menuItem = NSMenuItem(title: L10n.text(title), action: action, keyEquivalent: key)
        if !key.isEmpty { menuItem.keyEquivalentModifierMask = modifiers }
        menuItem.target = target
        menuItem.tag = tag
        return menuItem
    }

    /// A command whose key the user can change. The literal is gone from the
    /// call site: the shortcut table is what decides, and the title comes off
    /// the same case, so the row in Settings and the item here cannot drift.
    private func item(
        _ shortcut: ShortcutAction,
        _ action: Selector?,
        target: AnyObject? = nil,
        tag: Int = 0
    ) -> NSMenuItem {
        let menuItem = item(shortcut.titleKey, action, target: target, tag: tag)
        menuItem.applyShortcut(shortcut)
        return menuItem
    }

    private func submenu(_ title: String, in mainMenu: NSMenu, _ items: [NSMenuItem]) {
        let holder = NSMenuItem()
        let menu = NSMenu(title: L10n.text(title))
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
            .separator(),
            item(.toggleComment, #selector(NotaTextView.toggleLineComment(_:))),
            item(.indent, #selector(NotaTextView.indentLines(_:))),
            item(.outdent, #selector(NotaTextView.outdentLines(_:))),
        ]
    }

    /// Rebuilt whole whenever the language or a shortcut changes. Internal
    /// rather than private so a test can build it without launching the app.
    func buildMenu() {
        installedLanguage = Preferences.shared.language
        installedShortcuts = Preferences.shared.shortcuts
        let mainMenu = NSMenu()

        submenu("Nota", in: mainMenu, [
            item("About Nota", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item(.settings, #selector(openSettings(_:)), target: self),
            .separator(),
            item("Hide Nota", #selector(NSApplication.hide(_:)), key: "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)),
                 key: "h", modifiers: [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Nota", #selector(NSApplication.terminate(_:)), key: "q"),
        ])

        let recentMenu = NSMenu(title: L10n.text("Open Recent"))
        recentMenu.delegate = recentDocumentsMenu
        let recentItem = NSMenuItem(title: L10n.text("Open Recent"), action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu

        let bookmarksItem = NSMenuItem(title: L10n.text("Bookmarks"), action: nil, keyEquivalent: "")
        bookmarksItem.submenu = bookmarksMenu.makeMenu()

        submenu("File", in: mainMenu, [
            item(.newTab, #selector(newTab(_:)), target: self),
            // ⌘N is Nota's older new-tab key, and also what brings a hidden
            // window back; ⇧⌘N is the window itself. It is fixed: the
            // adjustable New Tab is the one above.
            item("New Tab", #selector(newWindowOrTab(_:)), key: "n", target: self),
            item(.newWindow, #selector(newWindowItem(_:)), target: self),
            item(.openFile, #selector(openNote(_:)), target: self),
            recentItem,
            bookmarksItem,
            .separator(),
            item(.closeTab, #selector(closeTab(_:)), target: self),
            .separator(),
            item(.save, #selector(saveNote(_:)), target: self),
            item(.saveAs, #selector(saveNoteAs(_:)), target: self),
            item(.export, #selector(exportNote(_:)), target: self),
            item(.printTab, #selector(printNote(_:)), target: self),
            .separator(),
            item("Reveal in Finder", #selector(revealInFinder(_:)), key: "r",
                 modifiers: [.command, .option], target: self),
        ])

        let findMenu = NSMenu(title: L10n.text("Find"))
        let findAction = #selector(NSTextView.performTextFinderAction(_:))
        // Find and Replace and Use Selection stay as they are: neither is in
        // the shortcut table, so neither can move.
        findMenu.addItem(item(.find, findAction,
                              tag: NSTextFinder.Action.showFindInterface.rawValue))
        findMenu.addItem(item("Find and Replace…", findAction, key: "r",
                              tag: NSTextFinder.Action.showReplaceInterface.rawValue))
        findMenu.addItem(item(.findNext, findAction,
                              tag: NSTextFinder.Action.nextMatch.rawValue))
        findMenu.addItem(item(.findPrevious, findAction,
                              tag: NSTextFinder.Action.previousMatch.rawValue))
        findMenu.addItem(item("Use Selection for Find", findAction, key: "e",
                              tag: NSTextFinder.Action.setSearchString.rawValue))
        findMenu.addItem(item(.goToLine, #selector(goToLine(_:)), target: self))
        findMenu.addItem(.separator())
        findMenu.addItem(item(.searchAllNotes, #selector(searchAllNotes(_:)), target: self))
        let findItem = NSMenuItem(title: L10n.text("Find"), action: nil, keyEquivalent: "")
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
            item(.increaseFontSize, #selector(zoomIn(_:)), target: self),
            item(.decreaseFontSize, #selector(zoomOut(_:)), target: self),
            item(.actualSize, #selector(actualSize(_:)), target: self),
            .separator(),
            item(.showImages, #selector(toggleImageSidebar(_:)), target: self),
            item(.markdownPreview, #selector(toggleMarkdownPreview(_:)), target: self),
            item(.readingMode, #selector(toggleReadingMode(_:)), target: self),
            item(.zenMode, #selector(toggleZenMode(_:)), target: self),
        ])

        var windowItems: [NSMenuItem] = [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(.goToTab, #selector(showTabPicker(_:)), target: self),
            .separator(),
            item(.nextTab, #selector(selectNextTab(_:)), target: self),
            item(.previousTab, #selector(selectPreviousTab(_:)), target: self),
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
