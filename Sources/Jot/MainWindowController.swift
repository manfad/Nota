import AppKit
import UniformTypeIdentifiers

/// The whole UI: tab strip in the title bar, one plain-text editor, a status
/// line at the bottom.
///
/// There is a single `NSTextView`; switching tabs swaps that note's
/// `NSTextStorage` and `UndoManager` into it, which is what keeps undo from
/// bleeding between tabs.
final class MainWindowController: NSWindowController {

    private enum Layout {
        static let trafficLightInset: CGFloat = 82
        static let textPadding: CGFloat = 20
        static let textPaddingVertical: CGFloat = 14
        static let statusInset: CGFloat = 16
        static let editorTrailingGap: CGFloat = 4
        static let statusBarHeight: CGFloat = 26
        /// Keeps zen-mode text clear of the traffic-light zone.
        static let zenTopInset: CGFloat = 28
        static let zenTextPadding: CGFloat = 40
    }

    private let store: SessionStore
    private var notes: [Note] = []
    private var selectedIndex = 0

    private var preferences: Preferences { .shared }
    private var fontSize: CGFloat { preferences.fontSize }

    private let textView: JotTextView
    private let scrollView = NSScrollView()
    private var lineNumberRuler: LineNumberRulerView?
    private let tabBar = TabBarView()
    private lazy var imageSidebar = ImageSidebarView(topInset: 8)
    private let splitViewController = NSSplitViewController()
    private let editorPane = NSViewController()
    private let sidebarPane = NSViewController()
    private var sidebarItem: NSSplitViewItem?
    private var tabBarLeading: NSLayoutConstraint?
    private let statusSeparator = NSBox()
    private var editorTrailing: NSLayoutConstraint?

    /// Zen mode strips the window back to the text. Session only — it is
    /// never persisted, so Jot always opens with its chrome.
    private(set) var isZenMode = false
    private let zenDragRegion = DragRegionView()
    private var editorTopToTabBar: NSLayoutConstraint?
    private var editorTopToPane: NSLayoutConstraint?
    private var editorBottomToStatus: NSLayoutConstraint?
    private var editorBottomToPane: NSLayoutConstraint?
    private var sidebarWorkItem: DispatchWorkItem?

    /// The sidebar follows the note by default — it appears when the tab has
    /// images and goes away when it does not. ⌥⌘I pins it open or shut for
    /// the rest of the session; nothing about that is persisted.
    private enum SidebarVisibility { case followsNote, alwaysShown, alwaysHidden }
    private var sidebarVisibility: SidebarVisibility = .followsNote
    private var sidebarIsVisible = false
    private lazy var installedSidebarSide: SidebarSide = preferences.sidebarSide

    private let tabPicker = TabPickerPanel()
    private let searchField = NSSearchField()
    private let searchResults = SearchResultsPanel()
    private var searchWorkItem: DispatchWorkItem?
    private var tabBarTrailingToEdge: NSLayoutConstraint?
    private var tabBarTrailingToSearch: NSLayoutConstraint?

    /// The footer, lualine style: the vim badge and its pending keys on the
    /// left, the counts centred, the caret's line:col on the right.
    private let statusLabel = NSTextField(labelWithString: "")
    private let modeBadge = VimModeBadge()
    private let pendingKeysLabel = NSTextField(labelWithString: "")
    private let cursorLabel = NSTextField(labelWithString: "")
    private var countsLeadingToVim: NSLayoutConstraint?
    private var countsLeadingToEdge: NSLayoutConstraint?
    private var vimMode: VimMode = .normal

    /// Keeps the storage currently shown by the text view alive even before
    /// any note is installed.
    private var installedStorage: NSTextStorage
    private var saveWorkItem: DispatchWorkItem?

    // MARK: - Setup

    init(store: SessionStore) {
        self.store = store

        // Explicit TextKit 1 stack: `replaceTextStorage` is how a tab switch
        // swaps documents, and that lives on NSLayoutManager.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        self.installedStorage = storage
        self.textView = JotTextView(frame: .zero, textContainer: container)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = "Jot"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 260)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("JotMainWindow")

        editorPane.view = NSView()
        sidebarPane.view = NSView()
        // Keeps the thumbnails clear of the traffic lights when on the left.
        sidebarPane.view.additionalSafeAreaInsets = NSEdgeInsets(
            top: 8, left: 0, bottom: 0, right: 0
        )
        window.contentViewController = splitViewController

        buildUI()
        buildSidebarPane()
        rebuildSplitItems()
        restoreSession()

        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: Preferences.didChange, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI() {
        let content = editorPane.view
        content.wantsLayer = true

        let background = BackgroundView()
        background.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(background)

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.delegate = self
        content.addSubview(tabBar)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.placeholderString = "Search all notes"
        searchField.delegate = self
        searchField.isHidden = true
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = false
        content.addSubview(searchField)
        searchResults.delegate = self
        tabPicker.delegate = self

        configureTextView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.findBarPosition = .aboveContent
        content.addSubview(scrollView)

        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        lineNumberRuler = ruler
        applyLineNumberVisibility()

        let separator = statusSeparator
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(separator)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        // The centre gives way to the two fixed regions rather than pushing
        // into them, so a narrow window truncates the counts instead.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.addSubview(statusLabel)

        modeBadge.translatesAutoresizingMaskIntoConstraints = false
        modeBadge.setMode(vimMode)
        content.addSubview(modeBadge)

        for label in [pendingKeysLabel, cursorLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            content.addSubview(label)
        }

        zenDragRegion.translatesAutoresizingMaskIntoConstraints = false
        zenDragRegion.isHidden = true
        content.addSubview(zenDragRegion)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            tabBar.topAnchor.constraint(equalTo: content.topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),

            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            searchField.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 220),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),

            zenDragRegion.topAnchor.constraint(equalTo: content.topAnchor),
            zenDragRegion.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            zenDragRegion.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            zenDragRegion.heightAnchor.constraint(equalToConstant: Layout.zenTopInset),

            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: content.bottomAnchor,
                                              constant: -Layout.statusBarHeight),

            modeBadge.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                               constant: Layout.statusInset),
            modeBadge.centerYAnchor.constraint(equalTo: separator.bottomAnchor,
                                               constant: Layout.statusBarHeight / 2),

            pendingKeysLabel.leadingAnchor.constraint(equalTo: modeBadge.trailingAnchor,
                                                      constant: 8),
            pendingKeysLabel.centerYAnchor.constraint(equalTo: modeBadge.centerYAnchor),

            cursorLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                                  constant: -Layout.statusInset),
            cursorLabel.centerYAnchor.constraint(equalTo: modeBadge.centerYAnchor),

            statusLabel.centerYAnchor.constraint(equalTo: modeBadge.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: cursorLabel.leadingAnchor,
                                                  constant: -12),
        ])

        // Centred in the footer, but only as far as the left and right
        // regions allow — hence the yielding priority.
        let centred = statusLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor)
        centred.priority = .defaultHigh
        centred.isActive = true

        countsLeadingToVim = statusLabel.leadingAnchor.constraint(
            greaterThanOrEqualTo: pendingKeysLabel.trailingAnchor, constant: 12
        )
        countsLeadingToEdge = statusLabel.leadingAnchor.constraint(
            greaterThanOrEqualTo: content.leadingAnchor, constant: Layout.statusInset
        )
        applyFooterVisibility()

        tabBarTrailingToEdge = tabBar.trailingAnchor.constraint(
            equalTo: content.trailingAnchor, constant: -8
        )
        tabBarTrailingToSearch = tabBar.trailingAnchor.constraint(
            equalTo: searchField.leadingAnchor, constant: -8
        )
        tabBarTrailingToEdge?.isActive = true

        tabBarLeading = tabBar.leadingAnchor.constraint(
            equalTo: content.leadingAnchor, constant: Layout.trafficLightInset
        )
        tabBarLeading?.isActive = true

        // A small breathing gap so the scroller never touches the pane edge
        // (or the sidebar divider).
        editorTrailing = scrollView.trailingAnchor.constraint(
            equalTo: content.trailingAnchor, constant: -Layout.editorTrailingGap
        )
        editorTrailing?.isActive = true

        editorTopToTabBar = scrollView.topAnchor.constraint(equalTo: tabBar.bottomAnchor)
        editorTopToPane = scrollView.topAnchor.constraint(
            equalTo: content.topAnchor, constant: Layout.zenTopInset
        )
        editorBottomToStatus = scrollView.bottomAnchor.constraint(
            equalTo: statusSeparator.topAnchor
        )
        editorBottomToPane = scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        editorTopToTabBar?.isActive = true
        editorBottomToStatus?.isActive = true

        applyEditorInsets()
    }

    private func buildSidebarPane() {
        let container = sidebarPane.view
        imageSidebar.translatesAutoresizingMaskIntoConstraints = false
        imageSidebar.assets = store.assets
        imageSidebar.delegate = self
        container.addSubview(imageSidebar)
        NSLayoutConstraint.activate([
            imageSidebar.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            imageSidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageSidebar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageSidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// A real sidebar item on the left, an inspector item on the right — both
    /// give the native translucent material, the full-height look under the
    /// titlebar, and animated collapsing for free.
    private func rebuildSplitItems() {
        let wasCollapsed = sidebarItem?.isCollapsed ?? !sidebarIsVisible
        for item in splitViewController.splitViewItems {
            splitViewController.removeSplitViewItem(item)
        }

        let editorItem = NSSplitViewItem(viewController: editorPane)
        editorItem.minimumThickness = 360
        editorItem.canCollapse = false

        let side = preferences.sidebarSide
        let item = side == .left
            ? NSSplitViewItem(sidebarWithViewController: sidebarPane)
            : NSSplitViewItem(inspectorWithViewController: sidebarPane)
        item.minimumThickness = 130
        item.maximumThickness = 240
        item.canCollapse = true
        item.collapseBehavior = .preferResizingSplitViewWithFixedSiblings
        item.isCollapsed = wasCollapsed

        if side == .left {
            splitViewController.addSplitViewItem(item)
            splitViewController.addSplitViewItem(editorItem)
        } else {
            splitViewController.addSplitViewItem(editorItem)
            splitViewController.addSplitViewItem(item)
        }
        sidebarItem = item
        updateTabStripInset()
    }

    /// The strip clears the traffic lights only when they sit over the editor
    /// pane — with a left sidebar showing, they are over the sidebar instead.
    private func updateTabStripInset() {
        let leftSidebarShowing =
            preferences.sidebarSide == .left && !(sidebarItem?.isCollapsed ?? true)
        tabBarLeading?.constant = leftSidebarShowing ? 12 : Layout.trafficLightInset
    }

    private func configureTextView() {
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: Layout.textPadding, height: Layout.textPaddingVertical)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.delegate = self
        textView.assets = store.assets
        textView.attributesProvider = { [weak self] in
            self?.defaultAttributes ?? [:]
        }
        textView.onChipClick = { [weak self] characterIndex in
            self?.revealChip(atCharacter: characterIndex)
        }
    }

    // MARK: - Text attributes

    private var defaultAttributes: [NSAttributedString.Key: Any] {
        preferences.textAttributes()
    }

    private func applyTextAttributes() {
        textView.font = preferences.font()
        textView.textColor = .textColor
        textView.defaultParagraphStyle = preferences.paragraphStyle()
        textView.typingAttributes = defaultAttributes
        applyEditorInsets()
    }

    /// Symmetric, so both margins match the padding setting and the scroll
    /// view stays flush with the pane (and the scroller with the sidebar).
    private var horizontalTextInset: CGFloat {
        isZenMode ? Layout.zenTextPadding : preferences.padding.inset
    }

    private func applyEditorInsets() {
        textView.textContainerInset = NSSize(
            width: horizontalTextInset, height: Layout.textPaddingVertical
        )
    }

    fileprivate func applyLineNumberVisibility() {
        // The gutter is chrome, so zen hides it whatever the setting says.
        scrollView.rulersVisible = preferences.showsLineNumbers && !isZenMode
        lineNumberRuler?.setFontSize(preferences.fontSize)
        applyEditorInsets()
    }

    /// Restyles every tab, not just the visible one, so switching tabs after a
    /// settings change never shows stale type.
    @objc private func preferencesChanged() {
        let attributes = defaultAttributes
        let font = preferences.font()
        for note in notes {
            let full = NSRange(location: 0, length: note.storage.length)
            note.storage.beginEditing()
            // `addAttributes` merges; `setAttributes` would drop `.attachment`
            // and leave every image as a stray placeholder character.
            note.storage.addAttributes(attributes, range: full)
            // Chips are measured from the font, so they must be redrawn too.
            var number = 1
            note.storage.enumerateAttribute(.attachment, in: full) { value, _, _ in
                guard let chip = value as? JotImageAttachment else { return }
                chip.updateChip(font: font, index: number)
                number += 1
            }
            note.storage.endEditing()
        }
        applyTextAttributes()
        applyLineNumberVisibility()
        if preferences.sidebarSide != installedSidebarSide {
            installedSidebarSide = preferences.sidebarSide
            rebuildSplitItems()
        }
        refreshImages(force: true)
        applyFooterVisibility()
        updateStatus()
        scheduleSave()
    }

    // MARK: - Session restore

    private func restoreSession() {
        let state = store.load()
        if let sessionFontSize = state?.fontSize {
            preferences.fontSize = CGFloat(sessionFontSize)
        }

        for tab in state?.tabs ?? [] {
            notes.append(makeRestoredNote(from: tab))
        }
        if notes.isEmpty {
            notes.append(makeUntitledNote())
        }
        normalizeUntitledNames()

        selectedIndex = state?.selectedTabID
            .flatMap { id in notes.firstIndex { $0.id == id } } ?? 0

        store.pruneCache(keeping: notes.map(\.id))
        installCurrentNote()
        refreshTabs()
        updateStatus()
        refreshImages(force: true)
        flush()
    }

    /// The cache is the source of truth for a dirty tab. A clean tab re-reads
    /// its file so external edits show up; a file that has gone missing keeps
    /// the cached text and is marked dirty so nothing is lost.
    private func makeRestoredNote(from tab: SessionTab) -> Note {
        let fileURL = tab.path.map { URL(fileURLWithPath: $0) }
        var text = store.readText(for: tab.id) ?? ""
        var isDirty = tab.isDirty

        if let fileURL {
            if let onDisk = try? String(contentsOf: fileURL, encoding: .utf8) {
                if !isDirty { text = onDisk }
            } else {
                isDirty = true
            }
        }

        let note = Note(
            id: tab.id,
            fileURL: fileURL,
            untitledName: fileURL == nil ? tab.untitledName : nil,
            text: text,
            attributes: defaultAttributes,
            assets: store.assets
        )
        note.isDirty = isDirty
        note.selectionLocation = max(0, min(tab.selection, note.storage.length))
        return note
    }

    private func normalizeUntitledNames() {
        for note in notes where note.fileURL == nil && note.untitledName == nil {
            note.untitledName = UntitledNaming.nextName(existing: notes.map(\.title))
        }
    }

    private func makeUntitledNote() -> Note {
        Note(
            id: UUID(),
            fileURL: nil,
            untitledName: UntitledNaming.nextName(existing: notes.map(\.title)),
            text: "",
            attributes: defaultAttributes,
            assets: store.assets
        )
    }

    // MARK: - Tabs

    private var currentNote: Note? {
        notes.indices.contains(selectedIndex) ? notes[selectedIndex] : nil
    }

    private func installCurrentNote() {
        guard let note = currentNote, let layoutManager = textView.layoutManager else { return }
        textView.breakUndoCoalescing()
        layoutManager.replaceTextStorage(note.storage)
        installedStorage = note.storage
        applyTextAttributes()
        let location = max(0, min(note.selectionLocation, note.storage.length))
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        window?.makeFirstResponder(textView)
        lineNumberRuler?.refresh()
    }

    private func refreshTabs() {
        tabBar.setItems(
            notes.map { TabBarItem(title: $0.title, isDirty: $0.isDirty) },
            selectedIndex: selectedIndex
        )
    }

    private func updateStatus() {
        let plain = currentNote?.text ?? ""
        statusLabel.stringValue = TextStats.counts(
            NoteText.strippingTokens(plain),
            images: NoteText.assetIDs(in: plain).count,
            lines: TextStats.lineCount(currentNote?.storage.string ?? "")
        )
        updateCursorPosition()
    }

    /// The caret's 1-based line and column, at the right of the footer.
    private func updateCursorPosition() {
        let text = (currentNote?.storage.string ?? "") as NSString
        cursorLabel.stringValue = TextStats.position(
            in: text, at: textView.selectedRange().location
        )
    }

    // MARK: - Vim footer

    /// Called by the engine when the mode changes; the badge is the only
    /// thing on screen that shows it.
    func setVimMode(_ mode: VimMode) {
        guard mode != vimMode else { return }
        vimMode = mode
        modeBadge.setMode(mode)
    }

    /// "showcmd": the count, operator and register typed so far, or the macro
    /// being recorded. Empty hides the label.
    func setVimPendingKeys(_ keys: String) {
        pendingKeysLabel.stringValue = keys
        applyFooterVisibility()
    }

    /// The footer's three regions, for the layout tests: the vim badge, the
    /// centred counts, and the caret position.
    var footerRegions: (badge: NSView, pendingKeys: NSTextField,
                        counts: NSTextField, cursor: NSTextField) {
        (modeBadge, pendingKeysLabel, statusLabel, cursorLabel)
    }

    /// The badge and its pending keys belong to vim mode; the caret position
    /// is always there. Zen takes the lot away.
    private func applyFooterVisibility() {
        let isVim = preferences.vimMode
        countsLeadingToEdge?.isActive = !isVim
        countsLeadingToVim?.isActive = isVim
        modeBadge.isHidden = isZenMode || !isVim
        pendingKeysLabel.isHidden =
            isZenMode || !isVim || pendingKeysLabel.stringValue.isEmpty
        cursorLabel.isHidden = isZenMode
    }

    func selectTab(at index: Int) {
        guard notes.indices.contains(index), index != selectedIndex else { return }
        currentNote?.selectionLocation = textView.selectedRange().location
        flushAll()
        selectedIndex = index
        installCurrentNote()
        refreshTabs()
        updateStatus()
        refreshImages(force: true)
        flush()
    }

    func addTab(fileURL: URL? = nil, text: String = "") {
        let note: Note
        if let fileURL {
            note = Note(id: UUID(), fileURL: fileURL, untitledName: nil,
                        text: text, attributes: defaultAttributes, assets: store.assets)
        } else {
            note = makeUntitledNote()
        }
        notes.insert(note, at: min(selectedIndex + 1, notes.count))
        selectedIndex = notes.firstIndex { $0 === note } ?? notes.count - 1
        store.writeText(note.text, for: note.id)
        installCurrentNote()
        refreshTabs()
        updateStatus()
        refreshImages(force: true)
        flush()
    }

    func closeTab(at index: Int) {
        guard notes.indices.contains(index) else { return }
        let note = notes[index]

        if note.isDirty {
            switch confirmDiscard(note) {
            case .alertFirstButtonReturn:
                guard save(note: note, forcePanel: false) else { return }
            case .alertThirdButtonReturn:
                return
            default:
                break
            }
        }

        let wasSelected = index == selectedIndex
        store.deleteText(for: note.id)
        notes.remove(at: index)

        if notes.isEmpty {
            notes.append(makeUntitledNote())
            selectedIndex = 0
            store.writeText("", for: notes[0].id)
            installCurrentNote()
        } else {
            if index < selectedIndex {
                selectedIndex -= 1
            } else if wasSelected {
                selectedIndex = min(index, notes.count - 1)
            }
            if wasSelected { installCurrentNote() }
        }

        refreshTabs()
        updateStatus()
        refreshImages(force: true)
        flush()
    }

    private func confirmDiscard(_ note: Note) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(note.title)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        let dontSave = alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        // Save keeps Return and Cancel keeps Escape; ⌘D is the standard key
        // for Don't Save in a save-changes sheet.
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = [.command]
        return alert.runModal()
    }

    // MARK: - Files

    @discardableResult
    func save(note: Note, forcePanel: Bool) -> Bool {
        var destination = note.fileURL
        if destination == nil || forcePanel {
            guard let chosen = runSavePanel(for: note) else { return false }
            destination = chosen
        }
        guard let destination else { return false }

        do {
            try Data(note.text.utf8).write(to: destination, options: .atomic)
        } catch {
            presentFailure("Couldn’t save “\(destination.lastPathComponent)”.", error)
            return false
        }

        note.fileURL = destination
        note.isDirty = false
        refreshTabs()
        flushAll()
        return true
    }

    private func runSavePanel(for note: Note) -> URL? {
        let panel = NSSavePanel()
        // Markdown by default, plain text still allowed. `UTType.markdown`
        // is not in this SDK, so it comes from the extension.
        let markdown = UTType(filenameExtension: "md") ?? .plainText
        panel.allowedContentTypes = [markdown, .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let existing = note.fileURL {
            panel.directoryURL = existing.deletingLastPathComponent()
            panel.nameFieldStringValue = existing.lastPathComponent
        } else {
            panel.directoryURL = preferences.lastSaveDirectory
                ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            panel.nameFieldStringValue = SuggestedName.from(text: note.countableText)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // Next save opens where this one landed.
        preferences.lastSaveDirectory = url.deletingLastPathComponent()
        return url
    }

    func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url: url) }
    }

    func open(url: URL) {
        let target = url.standardizedFileURL
        if let index = notes.firstIndex(where: { $0.fileURL?.standardizedFileURL == target }) {
            selectTab(at: index)
            return
        }
        guard let text = try? String(contentsOf: target, encoding: .utf8) else {
            presentFailure("Couldn’t open “\(target.lastPathComponent)”.",
                           nil, detail: "Jot only opens UTF-8 plain text files.")
            return
        }
        addTab(fileURL: target, text: text)
    }

    private func presentFailure(_ message: String, _ error: Error?, detail: String? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail ?? error?.localizedDescription ?? ""
        alert.runModal()
    }

    // MARK: - Persistence

    /// Debounced: fires ~300 ms after the last edit.
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// Writes the visible tab's text plus `session.json`.
    private func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        if let note = currentNote {
            note.selectionLocation = textView.selectedRange().location
            store.writeText(note.text, for: note.id)
        }
        writeSessionFile()
    }

    /// Writes every tab. Used on tab switch, window close and termination.
    func flushAll() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        currentNote?.selectionLocation = textView.selectedRange().location
        for note in notes { store.writeText(note.text, for: note.id) }
        writeSessionFile()
    }

    private func writeSessionFile() {
        store.save(SessionState(
            tabs: notes.map { $0.sessionTab() },
            selectedTabID: currentNote?.id,
            fontSize: Double(fontSize)
        ))
    }

    // MARK: - Font size

    /// Writes through to `Preferences`; the change notification restyles the
    /// editor and moves the Settings window's stepper.
    func setFontSize(_ size: CGFloat) {
        preferences.fontSize = size
    }

    var currentFontSize: CGFloat { fontSize }

    @objc private func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    // MARK: - Menu actions (forwarded from the app delegate)

    func newTab() { addTab() }

    func closeCurrentTab() { closeTab(at: selectedIndex) }

    func saveCurrent(forcePanel: Bool) {
        guard let note = currentNote else { return }
        save(note: note, forcePanel: forcePanel)
    }

    func selectNextTab() {
        guard notes.count > 1 else { return }
        selectTab(at: (selectedIndex + 1) % notes.count)
    }

    func selectPreviousTab() {
        guard notes.count > 1 else { return }
        selectTab(at: (selectedIndex - 1 + notes.count) % notes.count)
    }

    func focusEditor() {
        window?.makeFirstResponder(textView)
    }
}

// MARK: - Zen mode

extension MainWindowController {

    /// ⌥⌘Z. Everything but the text goes away; ⌘ shortcuts all keep working.
    func toggleZenMode() {
        setZenMode(!isZenMode)
    }

    private func setZenMode(_ enabled: Bool) {
        guard enabled != isZenMode else { return }
        isZenMode = enabled

        let chrome: [NSView] = [
            tabBar, statusSeparator, statusLabel,
            modeBadge, pendingKeysLabel, cursorLabel,
        ]

        editorTopToTabBar?.isActive = !enabled
        editorTopToPane?.isActive = enabled
        editorBottomToStatus?.isActive = !enabled
        editorBottomToPane?.isActive = enabled
        zenDragRegion.isHidden = !enabled

        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(button)?.isHidden = enabled
        }

        if enabled, !searchField.isHidden { endSearchAllNotes() }

        applyLineNumberVisibility()
        applyTextAttributes()

        if enabled {
            sidebarItem?.animator().isCollapsed = true
        } else {
            // Back to whatever the note and the session pin ask for.
            refreshImages(force: true)
        }

        // The only thing that animates is the chrome fading out or in.
        if !enabled {
            for view in chrome {
                view.isHidden = false
                view.alphaValue = 0
            }
            // The badge and its pending keys only come back if vim mode
            // actually wants them.
            applyFooterVisibility()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            for view in chrome { view.animator().alphaValue = enabled ? 0 : 1 }
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if self.isZenMode == enabled, enabled {
                for view in chrome { view.isHidden = true }
            }
        })
    }
}

/// A transparent strip that lets the window be dragged by its top edge once
/// the title bar's own chrome is gone.
private final class DragRegionView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// The vim mode chip at the left of the footer: a filled rounded rect with
/// the mode's name in it, coloured per mode the way a lualine bar is.
private final class VimModeBadge: NSView {
    private static let height: CGFloat = 18
    private static let horizontalPadding: CGFloat = 8

    private let label = NSTextField(labelWithString: "")
    /// The command line keeps whatever colour it was opened from, so the fill
    /// is held here rather than derived from the mode on every draw.
    private var fillColor: NSColor = .controlAccentColor

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4

        label.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let leading = label.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: Self.horizontalPadding
        )
        let trailing = label.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: -Self.horizontalPadding
        )
        // Just short of required, so an unusually narrow footer squeezes the
        // chip instead of logging a broken constraint.
        leading.priority = .required - 1
        trailing.priority = .required - 1
        NSLayoutConstraint.activate([
            leading, trailing,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setMode(_ mode: VimMode) {
        label.stringValue = mode.badgeTitle.uppercased()
        if let color = mode.badgeColor {
            fillColor = color
            needsDisplay = true
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Accent and system colours are appearance-dependent; resolving them
        // under the view's own appearance is what keeps dark mode right.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fillColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Tab picker

extension MainWindowController {

    /// ⌘P.
    func showTabPicker() {
        guard let window else { return }
        showWindow(nil)
        tabPicker.show(
            titles: notes.map(\.title), selectedIndex: selectedIndex, over: window
        )
    }
}

extension MainWindowController: TabPickerPanelDelegate {
    func tabPicker(_ picker: TabPickerPanel, didChoose tabIndex: Int) {
        selectTab(at: tabIndex)
        focusEditor()
    }
}

// MARK: - Images: chips and sidebar

extension MainWindowController {

    var isImageSidebarVisible: Bool { sidebarIsVisible }

    /// ⌥⌘I. Pins the sidebar open or shut, overriding the follow-the-note
    /// default for the rest of the session.
    func toggleImageSidebar() {
        sidebarVisibility = sidebarIsVisible ? .alwaysHidden : .alwaysShown
        refreshImages(force: true)
    }

    /// Debounced so a burst of keystrokes renumbers once.
    fileprivate func scheduleImageRefresh() {
        sidebarWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refreshImages() }
        sidebarWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    /// One pass over the visible note: renumber the chips, resize the ones
    /// whose label changed, then bring the sidebar in line.
    fileprivate func refreshImages(force: Bool = false) {
        sidebarWorkItem?.cancel()
        sidebarWorkItem = nil
        guard let storage = currentNote?.storage else { return }

        let font = preferences.font()
        var assetIDs: [String] = []
        var resized: [NSRange] = []
        var number = 1

        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard let chip = value as? JotImageAttachment else { return }
            assetIDs.append(chip.assetID)
            if chip.updateChip(font: font, index: number) { resized.append(range) }
            number += 1
        }

        // A chip whose label changed width needs its line laid out again.
        if let layoutManager = textView.layoutManager {
            for range in resized {
                layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
                layoutManager.invalidateDisplay(forCharacterRange: range)
            }
        }

        applySidebarVisibility(imageCount: assetIDs.count)
        if sidebarIsVisible {
            imageSidebar.setAssetIDs(assetIDs, force: force)
            updateSidebarHighlight()
        }
    }

    private func applySidebarVisibility(imageCount: Int) {
        let shouldShow: Bool
        switch sidebarVisibility {
        case .followsNote: shouldShow = imageCount > 0
        case .alwaysShown: shouldShow = true
        case .alwaysHidden: shouldShow = false
        }
        guard shouldShow != sidebarIsVisible else { return }

        sidebarIsVisible = shouldShow
        sidebarItem?.animator().isCollapsed = !shouldShow
        updateTabStripInset()
    }

    /// Called when a chip is clicked: bring the sidebar out if it is away.
    fileprivate func revealSidebar() {
        guard !sidebarIsVisible else { return }
        sidebarVisibility = .alwaysShown
        refreshImages(force: true)
    }

    /// Every chip in the visible note, in document order — the same order the
    /// sidebar lists them in, so index N means the same picture in both.
    private func chipLocations() -> [Int] {
        guard let storage = currentNote?.storage else { return [] }
        var locations: [Int] = []
        storage.enumerateAttribute(
            .attachment, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            if value is JotImageAttachment { locations.append(range.location) }
        }
        return locations
    }

    /// Rings the sidebar item for the chip the caret is touching, or for any
    /// chip inside the selection.
    fileprivate func updateSidebarHighlight() {
        guard sidebarIsVisible else { return }
        let selection = textView.selectedRange()
        var highlighted: Set<Int> = []

        for (index, location) in chipLocations().enumerated() {
            if selection.length > 0 {
                if location >= selection.location, location < NSMaxRange(selection) {
                    highlighted.insert(index)
                }
            } else if location == selection.location || location == selection.location - 1 {
                highlighted.insert(index)
            }
        }

        imageSidebar.setHighlighted(highlighted)
        if let first = highlighted.min() { imageSidebar.scrollItemToVisible(first) }
    }
}

extension MainWindowController {
    /// Clicking a chip brings the sidebar out and points at that thumbnail.
    fileprivate func revealChip(atCharacter characterIndex: Int) {
        revealSidebar()
        guard let ordinal = chipLocations().firstIndex(of: characterIndex) else { return }
        imageSidebar.scrollItemToVisible(ordinal)
        updateSidebarHighlight()
    }
}

extension MainWindowController: ImageSidebarViewDelegate {
    /// Clicking a picture puts the caret on its chip.
    func imageSidebar(_ sidebar: ImageSidebarView, didActivateItemAt index: Int) {
        let locations = chipLocations()
        guard locations.indices.contains(index) else { return }
        textView.setSelectedRange(NSRange(location: locations[index], length: 1))
        textView.scrollRangeToVisible(textView.selectedRange())
        focusEditor()
        updateSidebarHighlight()
    }
}

// MARK: - Search across tabs

extension MainWindowController {

    /// ⇧⌘F. The per-note find bar (⌘F) is untouched.
    func beginSearchAllNotes() {
        showWindow(nil)
        searchField.isHidden = false
        tabBarTrailingToEdge?.isActive = false
        tabBarTrailingToSearch?.isActive = true
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
        runSearch()
    }

    func endSearchAllNotes() {
        searchWorkItem?.cancel()
        searchWorkItem = nil
        searchResults.hide()
        searchField.stringValue = ""
        searchField.isHidden = true
        tabBarTrailingToSearch?.isActive = false
        tabBarTrailingToEdge?.isActive = true
        focusEditor()
    }

    fileprivate func scheduleSearch() {
        searchWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.runSearch() }
        searchWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    fileprivate func runSearch() {
        guard let window, !searchField.isHidden else { return }
        let query = searchField.stringValue
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults.hide()
            return
        }
        // The storage string, not the serialized text: an image is one
        // character there, so every range lines up with the text view.
        let haystack = notes.map { (title: $0.title, text: $0.storage.string) }
        searchResults.show(
            matches: NoteSearch.matches(query: query, in: haystack),
            below: searchField,
            in: window
        )
    }

    fileprivate func moveSearchSelection(by delta: Int) {
        searchResults.moveSelection(by: delta)
    }

    fileprivate func commitSearchSelection() {
        guard let match = searchResults.selectedMatch else { return }
        reveal(match)
    }

    fileprivate func reveal(_ match: NoteSearchMatch) {
        let query = searchField.stringValue
        endSearchAllNotes()

        selectTab(at: match.tabIndex)
        guard let storage = textView.textStorage else { return }
        let location = min(match.rangeInText.location, storage.length)
        let length = min(match.rangeInText.length, storage.length - location)
        textView.setSelectedRange(NSRange(location: location, length: length))
        textView.scrollRangeToVisible(textView.selectedRange())

        // Hand the query to the find bar so ⌘G carries on from here.
        let findBoard = NSPasteboard(name: .find)
        findBoard.clearContents()
        findBoard.setString(query, forType: .string)
    }
}

extension MainWindowController: SearchResultsPanelDelegate {
    func searchResultsPanel(_ panel: SearchResultsPanel, didChoose match: NoteSearchMatch) {
        reveal(match)
    }
}

extension MainWindowController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        scheduleSearch()
    }

    /// Arrow keys drive the list while the field keeps focus.
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSearchSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSearchSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commitSearchSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endSearchAllNotes()
            return true
        default:
            return false
        }
    }
}

// MARK: - Delegates

extension MainWindowController: TabBarViewDelegate {
    func tabBar(_ bar: TabBarView, didSelect index: Int) {
        selectTab(at: index)
    }

    func tabBar(_ bar: TabBarView, didRequestCloseAt index: Int) {
        closeTab(at: index)
    }
}

extension MainWindowController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let note = currentNote else { return }
        if !note.isDirty {
            note.isDirty = true
            refreshTabs()
        }
        note.selectionLocation = textView.selectedRange().location
        updateStatus()
        scheduleImageRefresh()
        scheduleSave()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        currentNote?.selectionLocation = textView.selectedRange().location
        updateCursorPosition()
        updateSidebarHighlight()
        scheduleSave()
    }

    /// Per-tab undo: the text view asks its delegate, so undo history follows
    /// the note rather than the window.
    func undoManager(for view: NSTextView) -> UndoManager? {
        currentNote?.undoManager
    }
}

extension MainWindowController: NSWindowDelegate {
    /// Closing the window only hides it — nothing is ever lost, so there is
    /// nothing to prompt about.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        flushAll()
        sender.orderOut(nil)
        return false
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        currentNote?.undoManager
    }

    func windowDidResize(_ notification: Notification) {
        repositionSearchResults()
    }

    func windowDidMove(_ notification: Notification) {
        repositionSearchResults()
    }

    private func repositionSearchResults() {
        guard searchResults.isVisible, let window, !searchField.isHidden else { return }
        searchResults.position(below: searchField, in: window)
    }
}

// MARK: - Background

/// Fills the editor pane with the text background so the pane reads as one
/// sheet of paper; the sidebar keeps the system's own material.
private final class BackgroundView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
