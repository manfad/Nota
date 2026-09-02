import AppKit

/// The whole UI: a tab strip across the top of the window, one plain-text
/// editor under it, a status line at the bottom.
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
    private let scrollView = FindBarScrollView()
    private var lineNumberRuler: LineNumberRulerView?
    private let tabBar = TabBarView()
    /// The strip's paper and its hairline. The tabs and the ⇧⌘F field sit on
    /// it, and it runs the whole width of the window above the split view.
    private let tabStripBackground = TabStripBackgroundView()
    private lazy var imageSidebar = ImageSidebarView(topInset: 8)
    /// Everything below the strip. The window's content is the root view, not
    /// this, so the strip can span both columns.
    private let splitViewController = NSSplitViewController()
    private let rootViewController = NSViewController()
    private let editorPane = NSViewController()
    private let sidebarPane = NSViewController()
    private var sidebarItem: NSSplitViewItem?
    private let previewPane = NSViewController()
    private let markdownPreview = MarkdownPreviewView()
    private var previewItem: NSSplitViewItem?
    private var editorItem: NSSplitViewItem?
    private var previewWorkItem: DispatchWorkItem?
    /// The mode the layout is actually in — the tab in front says which one
    /// it wants, zen mode says which of them it may have.
    private var installedPreviewMode: PreviewMode = .off
    /// Whether the render is on screen right now, in either of the two modes
    /// that show it.
    private var previewIsVisible: Bool { installedPreviewMode != .off }
    /// The Markdown row, once per column: the editor's is the one on screen in
    /// the editor and split modes, the preview's in reading, where the editor
    /// column is collapsed and cannot hold one.
    private lazy var editorMarkdownRow = MarkdownRowView(
        target: self, action: #selector(previewModeControlChanged)
    )
    private lazy var previewMarkdownRow = MarkdownRowView(
        target: self, action: #selector(previewModeControlChanged)
    )
    private let statusSeparator = NSBox()
    private var editorTrailing: NSLayoutConstraint?

    /// Zen mode strips the window back to the text. Session only — it is
    /// never persisted, so Jot always opens with its chrome.
    private(set) var isZenMode = false
    private let zenDragRegion = DragRegionView()
    /// Where the editor's text starts: under its Markdown row, under the strip
    /// when the tab has no row, or clear of the traffic lights in zen.
    private var editorTopToRow: NSLayoutConstraint?
    private var editorTopToPane: NSLayoutConstraint?
    private var editorTopToZen: NSLayoutConstraint?
    private var editorBottomToStatus: NSLayoutConstraint?
    private var editorBottomToPane: NSLayoutConstraint?
    /// The render starts under the preview column's Markdown row in reading
    /// mode, and under the strip the rest of the time.
    private var previewTopToRow: NSLayoutConstraint?
    private var previewTopToPane: NSLayoutConstraint?
    /// The split view hangs off the strip, and off the window's own top edge
    /// in zen, where there is no strip to hang off.
    private var splitTopToStrip: NSLayoutConstraint?
    private var splitTopToRoot: NSLayoutConstraint?
    private var sidebarWorkItem: DispatchWorkItem?
    /// The chip most recently clicked, until the selection moves some other
    /// way — see `ChipHighlight`.
    private var clickedChipLocation: Int?

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
    /// The four numbers behind the middle label, kept so a relayout can
    /// re-fit the text without walking the note again.
    private var counts = (words: 0, characters: 0, images: 0, lines: 1)
    /// Never shown: a stand-in used to measure a candidate string exactly as
    /// the real label would lay it out.
    private let countsRuler = NSTextField(labelWithString: "")

    /// Vim's state machine. One per window: the mode is global, so switching
    /// tabs lands you in normal mode rather than wherever the last tab was.
    private lazy var vimEngine = VimEngine(textView: textView)
    private var footerMessageWorkItem: DispatchWorkItem?
    /// The one-line pane above the footer where `:` and `/` are typed.
    private let commandPane = VimCommandPane(inset: Layout.statusInset)
    private var paneBottomToStatus: NSLayoutConstraint?
    private var paneBottomToContent: NSLayoutConstraint?
    /// True while a prompt is being typed in the pane.
    private var isCommandLineOpen = false

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

        let pane = PaneView()
        editorPane.view = pane
        // No inset of its own: the strip sits above the split view, so the
        // thumbnails start under it the way both other columns do.
        sidebarPane.view = NSView()
        // The window's content is the strip plus the split view under it, not
        // the split view alone — that is what lets the strip span both columns
        // while reading mode collapses one of them.
        rootViewController.view = NSView()
        window.contentViewController = rootViewController

        buildRoot()
        buildUI()
        // The counts are re-fitted once the two side regions have their
        // frames, which is the only moment their real widths are known.
        pane.onLayout = { [weak self] in self?.updateCountsLabel() }
        buildSidebarPane()
        buildPreviewPane()
        rebuildSplitItems()
        configureVim()
        restoreSession()

        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: Preferences.didChange, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The window's own layout: one tab strip across the top, and the split
    /// view — editor, preview, image sidebar — filling everything under it.
    /// The strip belongs to the window rather than to the editor column, so
    /// reading mode can collapse that column without taking the tabs with it.
    private func buildRoot() {
        let root = rootViewController.view
        root.wantsLayer = true

        rootViewController.addChild(splitViewController)
        let split = splitViewController.view
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)

        tabStripBackground.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabStripBackground)

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.delegate = self
        root.addSubview(tabBar)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.placeholderString = "Search all notes"
        searchField.delegate = self
        searchField.isHidden = true
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = false
        root.addSubview(searchField)
        searchResults.delegate = self
        tabPicker.delegate = self

        // Last in, so it lies over whichever column zen has left on screen.
        zenDragRegion.translatesAutoresizingMaskIntoConstraints = false
        zenDragRegion.isHidden = true
        root.addSubview(zenDragRegion)

        NSLayoutConstraint.activate([
            tabStripBackground.topAnchor.constraint(equalTo: root.topAnchor),
            tabStripBackground.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabStripBackground.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabStripBackground.heightAnchor.constraint(equalToConstant: TabBarView.height),

            // The tabs start clear of the traffic lights, which now sit over
            // the strip whichever side the image sidebar is on.
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            tabBar.leadingAnchor.constraint(
                equalTo: root.leadingAnchor, constant: Layout.trafficLightInset
            ),

            searchField.trailingAnchor.constraint(
                equalTo: root.trailingAnchor, constant: -12
            ),
            searchField.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 220),

            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            zenDragRegion.topAnchor.constraint(equalTo: root.topAnchor),
            zenDragRegion.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            zenDragRegion.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            zenDragRegion.heightAnchor.constraint(equalToConstant: Layout.zenTopInset),
        ])

        // The strip ends 12pt off the trailing edge, and 8pt short of the
        // ⇧⌘F field while that is open, so no tab ever runs under it.
        tabBarTrailingToEdge = tabBar.trailingAnchor.constraint(
            equalTo: root.trailingAnchor, constant: -12
        )
        tabBarTrailingToSearch = tabBar.trailingAnchor.constraint(
            equalTo: searchField.leadingAnchor, constant: -8
        )
        tabBarTrailingToEdge?.isActive = true

        splitTopToStrip = split.topAnchor.constraint(equalTo: tabStripBackground.bottomAnchor)
        splitTopToRoot = split.topAnchor.constraint(equalTo: root.topAnchor)
        splitTopToStrip?.isActive = true
    }

    private func buildUI() {
        let content = editorPane.view
        content.wantsLayer = true

        let background = BackgroundView()
        background.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(background)

        editorMarkdownRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(editorMarkdownRow)

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
        // The label takes exactly the width of its text — the text having
        // already been chosen to fit — so it never sits narrower than what it
        // is showing and quietly truncates. The two side gaps are required
        // constraints and still win, which is the last-resort safety net.
        statusLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        content.addSubview(statusLabel)

        modeBadge.translatesAutoresizingMaskIntoConstraints = false
        modeBadge.setMode(vimMode, animated: false)
        content.addSubview(modeBadge)

        // The pending keys are the badge's quiet companion, so they follow the
        // badge's type rather than the counts'.
        pendingKeysLabel.translatesAutoresizingMaskIntoConstraints = false
        pendingKeysLabel.font = .systemFont(ofSize: 11, weight: .medium)
        pendingKeysLabel.textColor = .tertiaryLabelColor
        content.addSubview(pendingKeysLabel)

        cursorLabel.translatesAutoresizingMaskIntoConstraints = false
        cursorLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        cursorLabel.textColor = .secondaryLabelColor
        content.addSubview(cursorLabel)

        // Last in, so it lies over the bottom of the editor rather than
        // taking room from it: opening `:` never moves the text.
        commandPane.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(commandPane)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            editorMarkdownRow.topAnchor.constraint(equalTo: content.topAnchor),
            editorMarkdownRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            editorMarkdownRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            editorMarkdownRow.heightAnchor.constraint(
                equalToConstant: MarkdownRowView.height
            ),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),

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

        NSLayoutConstraint.activate([
            commandPane.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            commandPane.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            commandPane.heightAnchor.constraint(equalToConstant: VimCommandPane.height),
        ])
        // It sits on the footer, and on the bottom of the window in zen mode,
        // where there is no footer to sit on.
        paneBottomToStatus = commandPane.bottomAnchor.constraint(
            equalTo: statusSeparator.topAnchor
        )
        paneBottomToContent = commandPane.bottomAnchor.constraint(
            equalTo: content.bottomAnchor
        )
        paneBottomToStatus?.isActive = true

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

        // A small breathing gap so the scroller never touches the pane edge
        // (or the sidebar divider).
        editorTrailing = scrollView.trailingAnchor.constraint(
            equalTo: content.trailingAnchor, constant: -Layout.editorTrailingGap
        )
        editorTrailing?.isActive = true

        editorTopToRow = scrollView.topAnchor.constraint(
            equalTo: editorMarkdownRow.bottomAnchor
        )
        editorTopToPane = scrollView.topAnchor.constraint(equalTo: content.topAnchor)
        editorTopToZen = scrollView.topAnchor.constraint(
            equalTo: content.topAnchor, constant: Layout.zenTopInset
        )
        editorBottomToStatus = scrollView.bottomAnchor.constraint(
            equalTo: statusSeparator.topAnchor
        )
        editorBottomToPane = scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        editorTopToRow?.isActive = true
        editorBottomToStatus?.isActive = true

        applyEditorInsets()
    }

    private func buildSidebarPane() {
        let container = sidebarPane.view
        imageSidebar.translatesAutoresizingMaskIntoConstraints = false
        imageSidebar.assets = store.assets
        imageSidebar.delegate = self
        imageSidebar.onSettings = { [weak self] in self?.openSettings(nil) }
        container.addSubview(imageSidebar)
        NSLayoutConstraint.activate([
            // Straight under the strip, like both the other columns: there is
            // no titlebar over this any more, so no band to keep clear of it.
            imageSidebar.topAnchor.constraint(equalTo: container.topAnchor),
            imageSidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageSidebar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageSidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    @objc private func previewModeControlChanged(_ sender: NSSegmentedControl) {
        let modes = PreviewMode.allCases
        guard modes.indices.contains(sender.selectedSegment) else { return }
        setPreviewMode(modes[sender.selectedSegment])
    }

    private func buildPreviewPane() {
        let container = previewPane.view
        markdownPreview.translatesAutoresizingMaskIntoConstraints = false
        markdownPreview.horizontalInset = preferences.padding.inset
        markdownPreview.onWidthChange = { [weak self] in
            self?.scheduleMarkdownPreviewRender()
        }
        markdownPreview.onBlockClick = { [weak self] source in
            self?.goToSource(source)
        }
        // Reading mode has no editor on screen: a key you could type into the
        // note brings it back first, and the key lands there.
        markdownPreview.onPrintableKey = { [weak self] event in
            self?.leaveReadingMode(for: { $0.keyDown(with: event) }) ?? false
        }
        markdownPreview.onFindAction = { [weak self] sender in
            self?.leaveReadingMode(for: { $0.performTextFinderAction(sender) }) ?? false
        }
        container.addSubview(markdownPreview)

        previewMarkdownRow.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(previewMarkdownRow)

        NSLayoutConstraint.activate([
            previewMarkdownRow.topAnchor.constraint(equalTo: container.topAnchor),
            previewMarkdownRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            previewMarkdownRow.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            previewMarkdownRow.heightAnchor.constraint(
                equalToConstant: MarkdownRowView.height
            ),

            markdownPreview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            markdownPreview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            markdownPreview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // The render starts under the row in reading mode, where the column
        // carries it, and under the strip in every other.
        previewTopToRow = markdownPreview.topAnchor.constraint(
            equalTo: previewMarkdownRow.bottomAnchor
        )
        previewTopToPane = markdownPreview.topAnchor.constraint(
            equalTo: container.topAnchor
        )
        previewTopToPane?.isActive = true
    }

    /// A real sidebar item on the left, an inspector item on the right — both
    /// give the native translucent material, the full-height look under the
    /// titlebar, and animated collapsing for free.
    private func rebuildSplitItems() {
        let wasCollapsed = sidebarItem?.isCollapsed ?? !sidebarIsVisible
        for item in splitViewController.splitViewItems {
            splitViewController.removeSplitViewItem(item)
        }

        let editor = NSSplitViewItem(viewController: editorPane)
        editor.minimumThickness = 360
        // Reading mode collapses the editor and gives the whole column to the
        // render. Same behaviour as the pane's: the siblings share the room
        // out and the window keeps the size it had.
        editor.canCollapse = true
        editor.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        editor.isCollapsed = installedPreviewMode == .reading

        // A plain item, not an inspector: the preview is the note's other
        // half rather than chrome about it, so it takes the paper background
        // and an even split rather than the system's translucent material.
        let preview = NSSplitViewItem(viewController: previewPane)
        preview.minimumThickness = 240
        preview.preferredThicknessFraction = 0.5
        preview.canCollapse = true
        // The window keeps its size and the editor gives up half its width —
        // the other way round, toggling the pane on and off after a zoom
        // leaves the window narrower than it started.
        preview.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        preview.isCollapsed = installedPreviewMode == .off

        let side = preferences.sidebarSide
        let item = side == .left
            ? NSSplitViewItem(sidebarWithViewController: sidebarPane)
            : NSSplitViewItem(inspectorWithViewController: sidebarPane)
        item.minimumThickness = 130
        item.maximumThickness = 240
        item.canCollapse = true
        // Like the preview: the editor makes room, the window stays put — the
        // sidebar shows itself whenever a note gains a picture, and a window
        // that changes width on a paste is not something anyone asked for.
        item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        item.isCollapsed = wasCollapsed

        // The images stay outermost whichever edge they are on; the preview
        // sits against the editor it belongs to.
        if side == .left {
            splitViewController.addSplitViewItem(item)
            splitViewController.addSplitViewItem(editor)
            splitViewController.addSplitViewItem(preview)
        } else {
            splitViewController.addSplitViewItem(editor)
            splitViewController.addSplitViewItem(preview)
            splitViewController.addSplitViewItem(item)
        }
        sidebarItem = item
        previewItem = preview
        editorItem = editor
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
        // A text file dropped on the editor is a note, not something to paste
        // into one — the editor hands it back here to open in its own tab.
        textView.onOpenFiles = { [weak self] urls in
            for url in urls { self?.open(url: url) }
        }
    }

    // MARK: - Text attributes

    /// The settings' attributes, with the right margin pushed in when the
    /// gutter has pulled the left one out (see `horizontalTextInset`).
    private var defaultAttributes: [NSAttributedString.Key: Any] {
        var attributes = preferences.textAttributes()
        let extra = trailingTextInsetExtra
        if extra > 0,
           let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy()
               as? NSMutableParagraphStyle {
            // A negative tail indent is measured from the trailing edge.
            style.tailIndent = -extra
            attributes[.paragraphStyle] = style
        }
        return attributes
    }

    private func applyTextAttributes() {
        markdownPreview.horizontalInset = preferences.padding.inset
        textView.font = preferences.font()
        textView.textColor = .textColor
        textView.defaultParagraphStyle = defaultAttributes[.paragraphStyle] as? NSParagraphStyle
        textView.typingAttributes = defaultAttributes
        applyEditorInsets()
    }

    /// With the gutter showing, the text sits this far off it — the numbers
    /// already keep 6pt of air on their side, so the two together read as one
    /// margin rather than the gutter plus a whole second padding.
    static let gutterTextGap: CGFloat = 8

    var isGutterVisible: Bool { preferences.showsLineNumbers && !isZenMode }

    /// The container inset is symmetric, so this is the left margin; when the
    /// gutter pulls it in, the right margin is kept at the setting through the
    /// paragraph style instead (`trailingTextInsetExtra`).
    var horizontalTextInset: CGFloat {
        if isZenMode { return Layout.zenTextPadding }
        return isGutterVisible ? Self.gutterTextGap : preferences.padding.inset
    }

    /// What the editor is typing with, for the tests.
    var editorParagraphStyle: NSParagraphStyle? { textView.defaultParagraphStyle }

    /// How much further in the right margin sits than the left.
    var trailingTextInsetExtra: CGFloat {
        isGutterVisible ? max(0, preferences.padding.inset - Self.gutterTextGap) : 0
    }

    private func applyEditorInsets() {
        textView.textContainerInset = NSSize(
            width: horizontalTextInset, height: Layout.textPaddingVertical
        )
    }

    fileprivate func applyLineNumberVisibility() {
        // The gutter is chrome, so zen hides it whatever the setting says.
        scrollView.rulersVisible = preferences.showsLineNumbers && !isZenMode
        lineNumberRuler?.showsSeparator = preferences.showsGutterSeparator
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
        applyPreviewMode()
        updateMarkdownRows()
        renderMarkdownPreview()
        vimEngine.isEnabled = preferences.vimMode
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
        // The session remembers the file's shape; only a session written
        // before Jot did has to ask the file again.
        var format = tab.format ?? .default

        if let fileURL {
            if let opened = TextFile.read(at: fileURL) {
                if !isDirty { text = opened.text }
                if tab.format == nil { format = opened.format }
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
            assets: store.assets,
            format: format
        )
        note.isDirty = isDirty
        note.selectionLocation = max(0, min(tab.selection, note.storage.length))
        // A session written before the pane was per-tab says nothing, and
        // those tabs come back without it.
        note.previewMode = tab.previewMode ?? .off
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
        // A scratch tab is vim's `'nomodifiable'`: the motions still work, the
        // keyboard does not.
        textView.isEditable = !note.isScratch
        vimEngine.isModifiable = !note.isScratch
        // Temporary attributes belong to the layout manager, not the note, so
        // the highlights are laid on again for whatever is now in it.
        vimEngine.refreshSearchHighlights()
        applyTextAttributes()
        let location = max(0, min(note.selectionLocation, note.storage.length))
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        lineNumberRuler?.refresh()
        // The mode belongs to the tab, so switching tabs opens, splits or
        // collapses for the tab you land on. Not animated: the tab's other
        // half is simply there or not, the way its text is, rather than
        // sliding in behind the note you asked for. It comes before the
        // keyboard is handed out — in reading mode the editor is collapsed
        // and cannot take it.
        applyPreviewMode(animated: false)
        updatePreviewModeControl()
        updateMarkdownRows()
        focusForPreviewMode()
        renderMarkdownPreview()
    }

    /// Also re-asks whether the tab in front is Markdown: ⌘S is where an
    /// untitled note gets a name, and a `.txt` has no row.
    private func refreshTabs() {
        tabBar.setItems(
            notes.map { TabBarItem(title: $0.title, isDirty: $0.isDirty) },
            selectedIndex: selectedIndex
        )
        updateMarkdownRows()
    }

    private func updateStatus() {
        let plain = currentNote?.text ?? ""
        let stripped = NoteText.strippingTokens(plain)
        counts = (
            words: TextStats.wordCount(stripped),
            characters: TextStats.characterCount(stripped),
            images: NoteText.assetIDs(in: plain).count,
            lines: TextStats.lineCount(currentNote?.storage.string ?? "")
        )
        updateCountsLabel()
        updateCursorPosition()
    }

    /// Writes the longest form of the counts that fits between the two side
    /// regions, so the middle sheds a whole segment — and finally its words —
    /// rather than truncating a phrase mid-way.
    private func updateCountsLabel() {
        let variants = TextStats.countVariants(
            words: counts.words, characters: counts.characters,
            images: counts.images, lines: counts.lines,
            segments: preferences.footerSegments
        )
        // Measured through a label of its own rather than off the string: a
        // text field lays out a few points wider than the type it holds, and
        // those points are the difference between fitting and being squeezed.
        countsRuler.font = statusLabel.font
        countsRuler.alignment = statusLabel.alignment
        countsRuler.lineBreakMode = statusLabel.lineBreakMode
        let width = availableCountsWidth
        let text = TextStats.variantFitting(variants, within: width) { candidate in
            countsRuler.stringValue = candidate
            return countsRuler.fittingSize.width
        }
        // Only on a real change: setting it invalidates the intrinsic size
        // and asks for another layout pass.
        if statusLabel.stringValue != text { statusLabel.stringValue = text }
    }

    /// The gap between the left region and the caret position, with the 12pt
    /// breathing space at each end already taken off.
    private var availableCountsWidth: CGFloat {
        // Before the first layout pass there are no frames to measure, so
        // nothing is ruled out yet.
        guard cursorLabel.frame.maxX > 0 else { return .greatestFiniteMagnitude }
        // Mirrors the two leading constraints exactly: 12pt clear of the
        // pending keys with vim mode on, the status inset without it.
        let leading = preferences.vimMode
            ? pendingKeysLabel.frame.maxX + 12
            : Layout.statusInset
        return max(0, cursorLabel.frame.minX - 12 - leading)
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

    /// Hands the engine the text view and the footer, and puts it in the
    /// state the setting asks for.
    private func configureVim() {
        vimEngine.host = self
        vimEngine.onModeChange = { [weak self] mode in self?.setVimMode(mode) }
        vimEngine.onPendingKeysChange = { [weak self] keys in self?.setVimPendingKeys(keys) }
        textView.vimKeyHandler = { [weak self] event in
            self?.vimEngine.handle(event) ?? false
        }
        vimEngine.isEnabled = preferences.vimMode
    }

    /// A word in the middle of the footer for a few seconds, then back to the
    /// counts — where "Not an editor command" and vimrc errors land.
    func showFooterMessage(_ message: String) {
        footerMessageWorkItem?.cancel()
        statusLabel.stringValue = message
        let item = DispatchWorkItem { [weak self] in self?.updateStatus() }
        footerMessageWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    /// The engine, for the tests to type at.
    var vim: VimEngine { vimEngine }

    /// Which tab is showing — for the tests that drive `gt` and `gT`.
    var selectedTabIndex: Int { selectedIndex }

    /// The command pane, for the tests: whether it is up, what it says, and
    /// whether that is a message rather than something being typed.
    var commandPaneState: (isVisible: Bool, text: String, isMessage: Bool) {
        (!commandPane.isHidden, commandPane.text, commandPane.isShowingMessage)
    }

    /// Every open tab, for the file tests: what it is called, what it holds,
    /// which file it came from and the shape a save would put back.
    var openNotes: [(title: String, text: String, fileURL: URL?, format: TextFileFormat)] {
        notes.map { ($0.title, $0.text, $0.fileURL, $0.format) }
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
        // Nothing to count means no label at all, rather than an empty gap.
        statusLabel.isHidden = isZenMode || preferences.footerSegments.isEmpty
    }

    func selectTab(at index: Int) {
        guard notes.indices.contains(index), index != selectedIndex else { return }
        currentNote?.selectionLocation = textView.selectedRange().location
        flushAll()
        selectedIndex = index
        installCurrentNote()
        if preferences.vimMode { vimEngine.enterNormalMode() }
        refreshTabs()
        updateStatus()
        refreshImages(force: true)
        flush()
    }

    func addTab(fileURL: URL? = nil, text: String = "",
                format: TextFileFormat = .default) {
        let note: Note
        if let fileURL {
            note = Note(id: UUID(), fileURL: fileURL, untitledName: nil,
                        text: text, attributes: defaultAttributes, assets: store.assets,
                        format: format)
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
        return write(note: note, to: destination)
    }

    /// The write itself, once somewhere to put it has been settled — by the
    /// panel, or by the name `:w` was given.
    @discardableResult
    private func write(note: Note, to destination: URL) -> Bool {
        // The file goes back in the shape it came in — same encoding, same
        // mark, same line endings — unless the text has outgrown it, which
        // `encode` says by handing back a format of its own.
        let encoded = TextFile.encode(note.text, format: note.format)
        do {
            try encoded.data.write(to: destination, options: .atomic)
        } catch {
            presentFailure("Couldn’t save “\(destination.lastPathComponent)”.", error)
            return false
        }

        note.format = encoded.format
        note.fileURL = destination
        note.isDirty = false
        preferences.lastSaveDirectory = destination.deletingLastPathComponent()
        refreshTabs()
        flushAll()
        return true
    }

    private func runSavePanel(for note: Note) -> URL? {
        let panel = NSSavePanel()
        // Every text type Jot knows, and `allowsOtherFileTypes` for the ones
        // it does not — a `.toml` typed into the panel stays a `.toml`.
        panel.allowedContentTypes = TextFile.contentTypes
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = SuggestedName.panelName(
            for: note.fileURL, text: note.countableText
        )
        if let existing = note.fileURL {
            panel.directoryURL = existing.deletingLastPathComponent()
        } else {
            panel.directoryURL = preferences.lastSaveDirectory
                ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // Next save opens where this one landed.
        preferences.lastSaveDirectory = url.deletingLastPathComponent()
        return url
    }

    /// No type filter: Notepad++ opens whatever you point it at, and the
    /// refusal — if there is one — comes from the bytes, not the panel.
    func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url: url) }
    }

    func open(url: URL) {
        let target = url.standardizedFileURL
        if let index = notes.firstIndex(where: { $0.fileURL?.standardizedFileURL == target }) {
            selectTab(at: index)
            return
        }
        guard let opened = TextFile.read(at: target) else {
            presentFailure("Couldn’t open “\(target.lastPathComponent)”.",
                           nil, detail: "Jot only opens text files.")
            return
        }
        addTab(fileURL: target, text: opened.text, format: opened.format)
        // The setting is about opening files, not about restoring them: a tab
        // coming back from the session keeps the mode it was left in.
        if preferences.opensMarkdownInReadingMode, Self.isMarkdown(target) {
            setPreviewMode(.reading)
        }
    }

    /// Markdown by extension, the way the save panel spells it.
    static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
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
            if !note.isScratch { store.writeText(note.text, for: note.id) }
        }
        writeSessionFile()
    }

    /// Writes every tab. Used on tab switch, window close and termination.
    func flushAll() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        currentNote?.selectionLocation = textView.selectedRange().location
        for note in notes where !note.isScratch { store.writeText(note.text, for: note.id) }
        writeSessionFile()
    }

    /// Scratch tabs are left out of both the session file and the cache, so
    /// `:help` is gone by the next launch rather than restored as a note.
    private func writeSessionFile() {
        let saved = notes.filter { !$0.isScratch }
        store.save(SessionState(
            tabs: saved.map { $0.sessionTab() },
            selectedTabID: (currentNote?.isScratch == true ? saved.first : currentNote)?.id,
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
            tabBar, tabStripBackground, statusSeparator, statusLabel,
            modeBadge, pendingKeysLabel, cursorLabel,
        ]

        // The strip goes, so the columns start at the window's own top edge;
        // the Markdown rows go with it, in `updateMarkdownRows`.
        splitTopToStrip?.isActive = false
        splitTopToRoot?.isActive = false
        (enabled ? splitTopToRoot : splitTopToStrip)?.isActive = true
        editorBottomToStatus?.isActive = !enabled
        editorBottomToPane?.isActive = enabled
        // The footer goes; the pane does not — `:` has to work in zen mode.
        paneBottomToStatus?.isActive = !enabled
        paneBottomToContent?.isActive = enabled
        zenDragRegion.isHidden = !enabled

        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(button)?.isHidden = enabled
        }

        if enabled, !searchField.isHidden { endSearchAllNotes() }

        // The gutter comes and goes with zen, and the margins with it — every
        // tab's paragraph style carries the right margin, so restyle them all.
        preferencesChanged()

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

/// The editor pane's own view. Identical to a plain `NSView` but for the
/// callback after each layout pass, which is when the footer's side regions
/// have the frames the middle label has to fit between.
private final class PaneView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// A transparent strip that lets the window be dragged by its top edge once
/// the title bar's own chrome is gone.
private final class DragRegionView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// A plain `NSScrollView` whose only job is to strip the focus ring off the
/// native find bar. `NSTextFinder` builds that bar lazily and installs it as
/// `findBarView` the first time ⌘F is used, so `didSet` is the one hook that
/// reliably sees it — whether it arrives via the menu, incremental search, or
/// AppKit re-creating the bar later.
private final class FindBarScrollView: NSScrollView {
    override var findBarView: NSView? {
        didSet { FindBarScrollView.removeFocusRing(from: findBarView) }
    }

    /// A few of the bar's own decorations (its buttons' and segments' title
    /// labels are `NSTextField`s too) are only realized once the bar lays
    /// itself out, which happens after `findBarView` is first set — so the
    /// sweep repeats on every layout pass to catch those as well. Walking a
    /// small, already-built tree is cheap, and setting a focus ring type that
    /// is already off is a no-op.
    override func layout() {
        super.layout()
        FindBarScrollView.removeFocusRing(from: findBarView)
    }

    /// Walks the bar's whole subview tree and turns off the focus ring on
    /// every field in it, including the replace field — the same treatment
    /// the ⌘P picker gives its own search field.
    static func removeFocusRing(from view: NSView?) {
        guard let view else { return }
        if let field = view as? NSTextField {
            field.focusRingType = .none
        }
        for subview in view.subviews {
            removeFocusRing(from: subview)
        }
    }
}

/// The command pane: one line above the footer where `:` `/` `?` are typed,
/// and where what they have to say appears afterwards.
///
/// It overlays the bottom of the editor rather than pushing it up, so opening
/// it never moves the text under the caret — and it is present in zen mode,
/// where the footer is not, because a command line you cannot see is a command
/// line you cannot use.
final class VimCommandPane: NSView {
    static let height: CGFloat = 22

    /// A caret drawn rather than blinked: the pane never takes first
    /// responder, so AppKit would not draw one for it.
    private static let caret = "\u{258F}"

    private let label = NSTextField(labelWithString: "")
    private let hairline = NSBox()
    private(set) var isShowingMessage = false

    init(inset: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        // Nothing to say yet: the pane is only there when it is holding
        // something.
        isHidden = true

        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),

            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A prompt being typed: its character quiet, what has been typed since
    /// in the text's own colour, and a bar caret after it.
    func showPrompt(_ text: String) {
        isShowingMessage = false
        let line = NSMutableAttributedString()
        let prefix = text.first.map(String.init) ?? ""
        line.append(NSAttributedString(
            string: prefix,
            attributes: [.font: label.font as Any, .foregroundColor: NSColor.secondaryLabelColor]
        ))
        line.append(NSAttributedString(
            string: String(text.dropFirst()) + Self.caret,
            attributes: [.font: label.font as Any, .foregroundColor: NSColor.labelColor]
        ))
        label.attributedStringValue = line
        isHidden = false
    }

    /// What a command or a search had to say, until the next key.
    func showMessage(_ message: String) {
        isShowingMessage = true
        label.attributedStringValue = NSAttributedString(
            string: message,
            attributes: [.font: label.font as Any, .foregroundColor: NSColor.secondaryLabelColor]
        )
        isHidden = false
    }

    func clear() {
        isShowingMessage = false
        label.stringValue = ""
        isHidden = true
    }

    /// What the tests read.
    var text: String { label.stringValue }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The vim mode chip at the left of the footer.
///
/// Monochrome on purpose: one quiet capsule, the mode's name in it, and no
/// colour anywhere. Insert — where you spend most of your time — drops the
/// capsule and shows the bare word.
private final class VimModeBadge: NSView {
    private static let height: CGFloat = 18
    private static let horizontalPadding: CGFloat = 8
    private static let fadeDuration: TimeInterval = 0.12

    private let label = NSTextField(labelWithString: "")
    private var mode: VimMode = .normal

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
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
        applyMode()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The word swaps under a short cross-fade; the capsule goes with it.
    /// Nothing else in the footer moves.
    func setMode(_ newMode: VimMode, animated: Bool = true) {
        guard newMode != mode else { return }
        mode = newMode
        guard animated else {
            applyMode()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration / 2
            label.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            // Reads the mode again rather than closing over it, so a burst of
            // changes still lands on the one the editor is actually in.
            self.applyMode()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration / 2
                self.label.animator().alphaValue = 1
            }
        })
    }

    private func applyMode() {
        label.stringValue = mode.badgeTitle
        label.alphaValue = 1
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // `labelColor` is appearance-dependent; resolving it under the view's
        // own appearance is what keeps dark mode right.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = Self.height / 2
            layer?.backgroundColor = mode.showsCapsule
                ? NSColor.labelColor.withAlphaComponent(0.06).cgColor
                : NSColor.clear.cgColor
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

// MARK: - Markdown preview

extension MainWindowController {

    /// Whether the render is up, what it is showing, and which mode the tab
    /// in front is in — for the tests.
    var previewState: (isVisible: Bool, renderedText: String, mode: PreviewMode) {
        (previewIsVisible, markdownPreview.renderedText, previewMode)
    }

    /// What the tab in front asks for — what the View menu's checkmarks say,
    /// whether or not zen is hiding the chrome at this moment.
    var previewMode: PreviewMode { currentNote?.previewMode ?? .off }

    /// ⇧⌘P. Off → split → reading → off. The mode belongs to the tab, not to
    /// the app: a Markdown note keeps it — across relaunches, through the
    /// session — while the next ⌘T opens in the editor.
    func toggleMarkdownPreview() {
        setPreviewMode(previewMode.next)
    }

    /// ⌥⇧⌘P. Straight to the render, and straight back out of it.
    func toggleReadingMode() {
        setPreviewMode(previewMode == .reading ? .off : .reading)
    }

    /// The one way the mode ever changes: the menu, ⇧⌘P, the row's control,
    /// a block click and a keystroke in reading mode all come through here.
    func setPreviewMode(_ mode: PreviewMode) {
        guard let note = currentNote else { return }
        note.previewMode = mode
        applyPreviewMode(animated: true)
        renderMarkdownPreview()
        updatePreviewModeControl()
        flush()
        focusForPreviewMode()
    }

    /// What the layout may show: the tab asks, zen answers. Zen keeps the
    /// text alone, so the pane beside the editor is chrome and goes; reading
    /// mode is not a pane beside anything — zen there is the render alone,
    /// which is the whole point of asking for it.
    private var effectivePreviewMode: PreviewMode {
        guard isZenMode else { return previewMode }
        return previewMode == .reading ? .reading : .off
    }

    /// Collapses and expands the two items to match. Leaving zen brings back
    /// whatever the tab asks for.
    private func applyPreviewMode(animated: Bool = true) {
        let mode = effectivePreviewMode
        guard mode != installedPreviewMode else { return }
        installedPreviewMode = mode
        // There is nothing to animate in a window nobody is looking at, and
        // an animation still in flight when the split items are rebuilt under
        // it — the sidebar changing sides — takes AppKit with it.
        let live = animated && window?.isVisible == true
        let preview = live ? previewItem?.animator() : previewItem
        let editor = live ? editorItem?.animator() : editorItem
        // Whichever item is about to hold the column is expanded first: the
        // two are never both collapsed, even for an instant.
        if mode == .reading {
            preview?.isCollapsed = false
            editor?.isCollapsed = true
        } else {
            editor?.isCollapsed = false
            preview?.isCollapsed = mode == .off
        }
        markdownPreview.takesKeyboard = mode == .reading
        updateMarkdownRows()
    }

    /// The render is read, not typed in — so the keyboard stays in the editor,
    /// except in reading mode, where the editor is not on screen to hold it.
    private func focusForPreviewMode() {
        if installedPreviewMode == .reading {
            markdownPreview.focus(in: window)
        } else {
            focusEditor()
        }
    }

    /// The mode control the reader can actually see — the editor column's row
    /// in the editor and split modes, the preview column's in reading. The two
    /// are kept in step, so either answers for the other; this is the one on
    /// screen, which is what a test asking about the layout wants.
    var previewModeControl: NSSegmentedControl {
        installedPreviewMode == .reading
            ? previewMarkdownRow.modeControl
            : editorMarkdownRow.modeControl
    }

    /// Both rows' controls follow the tab in front — a tab switch, ⇧⌘P, a
    /// block click, a keystroke in reading mode, a restored session.
    private func updatePreviewModeControl() {
        let index = PreviewMode.allCases.firstIndex(of: previewMode) ?? 0
        for control in [editorMarkdownRow.modeControl, previewMarkdownRow.modeControl]
        where control.selectedSegment != index {
            control.selectedSegment = index
        }
    }

    /// A Markdown tab is one whose file is spelled `.md` or `.markdown`, and
    /// an untitled one, which ⌘S saves as `.md` by default.
    private var currentNoteIsMarkdown: Bool {
        guard let note = currentNote else { return false }
        guard let fileURL = note.fileURL else { return true }
        return Self.isMarkdown(fileURL)
    }

    /// Which column carries the Markdown row, if either does, and where the
    /// text under it starts. Only a Markdown tab has a row at all, zen has
    /// none, and reading mode moves the one row it has across the divider —
    /// the editor column is collapsed there and cannot hold it.
    fileprivate func updateMarkdownRows() {
        let showsRow = currentNoteIsMarkdown && !isZenMode
        let onPreview = showsRow && installedPreviewMode == .reading
        let onEditor = showsRow && !onPreview

        editorMarkdownRow.setVisible(onEditor)
        previewMarkdownRow.setVisible(onPreview)

        // Deactivated before activated: two tops on one view, even for an
        // instant, is an unsatisfiable layout.
        editorTopToRow?.isActive = false
        editorTopToPane?.isActive = false
        editorTopToZen?.isActive = false
        if isZenMode {
            editorTopToZen?.isActive = true
        } else if onEditor {
            editorTopToRow?.isActive = true
        } else {
            editorTopToPane?.isActive = true
        }

        previewTopToRow?.isActive = false
        previewTopToPane?.isActive = false
        (onPreview ? previewTopToRow : previewTopToPane)?.isActive = true
    }

    /// Reading mode's way back to the text: the editor comes out from under
    /// the render, and whatever asked for it — a typed character, a ⌘F —
    /// happens there. `false` when there was no reading mode to leave, which
    /// leaves the pane to do its own thing with the event.
    private func leaveReadingMode(for action: (JotTextView) -> Void) -> Bool {
        guard previewMode == .reading else { return false }
        setPreviewMode(.split)
        action(textView)
        return true
    }

    /// Debounced, like the cache write: a burst of keystrokes re-renders once,
    /// about 150 ms after the typing stops.
    private func scheduleMarkdownPreviewRender() {
        guard previewIsVisible else { return }
        previewWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.renderMarkdownPreview() }
        previewWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func renderMarkdownPreview() {
        previewWorkItem?.cancel()
        previewWorkItem = nil
        guard previewIsVisible else { return }
        markdownPreview.show(MarkdownRenderer.render(
            currentNote?.text ?? "",
            font: preferences.font(),
            assets: store.assets,
            width: markdownPreview.contentWidth
        ))
        highlightPreviewBlock()
    }

    /// Lights the block the caret is in. Called on every selection change, so
    /// walking the note in the editor walks the pane beside it.
    fileprivate func highlightPreviewBlock() {
        guard previewIsVisible else { return }
        markdownPreview.highlightBlock(containingSource: textView.selectedRange().location)
    }

    /// A block was clicked in the pane: put the caret on the first character
    /// of the source it came from and show it.
    private func goToSource(_ source: NSRange) {
        guard let note = currentNote else { return }
        // Clicking a block in reading mode is asking for the text behind it,
        // so the editor comes back beside the render with the caret on it.
        if previewMode == .reading { setPreviewMode(.split) }
        let location = max(0, min(source.location, note.storage.length))
        // A jump is a move, not a typing session: vim comes back to normal
        // mode for it, the way `gg` or a mark would leave you.
        if preferences.vimMode, vimEngine.mode != .normal { vimEngine.enterNormalMode() }
        textView.setSelectedRange(NSRange(location: location, length: 0))
        if preferences.vimMode { vimEngine.clampCaret() }
        revealInEditor(textView.selectedRange())
        // The pane is read, not typed in.
        focusEditor()
    }

    /// Scrolls the editor to a place in the note. Somewhere already on screen
    /// is left where it is; somewhere off it is brought to the middle, which
    /// is where you want a block you have just jumped to.
    private func revealInEditor(_ range: NSRange) {
        let clip = scrollView.contentView
        let wasVisible = editorRect(for: range).map { clip.bounds.intersects($0) } ?? true
        textView.scrollRangeToVisible(range)
        guard !wasVisible, let rect = editorRect(for: range) else { return }
        let scrollable = max(0, textView.bounds.height - clip.bounds.height)
        let y = min(max(0, rect.midY - clip.bounds.height / 2), scrollable)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y.rounded()))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Where a piece of the note sits in the editor's document.
    private func editorRect(for range: NSRange) -> NSRect? {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let length = currentNote?.storage.length, length > 0
        else { return nil }
        // Nothing below the last laid-out line has a rectangle yet, and a
        // jump is usually to somewhere that has never been on screen.
        layoutManager.ensureLayout(for: container)
        let character = min(max(0, range.location), length - 1)
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        var rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        rect.origin.y += textView.textContainerOrigin.y
        rect.origin.x += textView.textContainerOrigin.x
        return rect
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
        let highlighted = ChipHighlight.resolve(
            clickedChipLocation: clickedChipLocation,
            selection: textView.selectedRange(),
            chipLocations: chipLocations(),
            caretIsBlock: textView.vimCursorStyle != .bar
        )
        imageSidebar.setHighlighted(highlighted)
        if let first = highlighted.min() { imageSidebar.scrollItemToVisible(first) }
    }
}

extension MainWindowController {
    /// Clicking a chip brings the sidebar out and points at that thumbnail.
    fileprivate func revealChip(atCharacter characterIndex: Int) {
        revealSidebar()
        // Set after `revealSidebar`, which moves the caret and so clears it.
        clickedChipLocation = characterIndex
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

// MARK: - Vim's window

extension MainWindowController: VimEngineHost {
    /// `gt` / `gT`, wrapping the way ⌃Tab does.
    func vimSelectTab(offset: Int) {
        guard notes.count > 1, offset != 0 else { return }
        let count = notes.count
        let target = ((selectedIndex + offset) % count + count) % count
        selectTab(at: target)
    }

    /// In vim mode the pane is where the engine speaks; the footer keeps the
    /// counts. Everything else in the app still uses the footer.
    func vimShow(message: String) {
        guard preferences.vimMode else {
            showFooterMessage(message)
            return
        }
        commandPane.showMessage(message)
    }

    /// The prompt lives in the pane above the footer — the text view never
    /// gives up first responder, so the note's own caret and scroll position
    /// stay exactly where they were.
    func vimCommandLineChanged(_ text: String?) {
        isCommandLineOpen = text != nil
        if let text {
            commandPane.showPrompt(text)
        } else {
            commandPane.clear()
        }
    }

    /// A message stays in the pane until the next key.
    func vimClearMessage() {
        guard !isCommandLineOpen else { return }
        commandPane.clear()
    }

    /// `:w` alone is ⌘S. `:w name` writes that name into the folder the last
    /// save used, with no panel — a path with a slash in it is taken as it is.
    func vimSave(name: String?) -> Bool {
        guard let note = currentNote else { return false }
        guard let name, !name.isEmpty else { return save(note: note, forcePanel: false) }
        return write(note: note, to: resolvedURL(for: name, near: note))
    }

    func vimClose(force: Bool) {
        guard let note = currentNote else { return }
        if force { note.isDirty = false }
        closeTab(at: selectedIndex)
    }

    func vimOpen(path: String) {
        let url = resolvedURL(for: path, near: currentNote)
        guard FileManager.default.fileExists(atPath: url.path) else {
            showFooterMessage("E484: Can’t open file \(path)")
            return
        }
        open(url: url)
    }

    func vimNewTab() {
        addTab()
    }

    /// `:help`, `:reg`, `:marks`. A second `:help` comes back to the tab that
    /// is already open rather than stacking another one beside it.
    func vimOpenScratchTab(title: String, text: String) {
        if let index = notes.firstIndex(where: { $0.isScratch && $0.title == title }) {
            let note = notes[index]
            note.storage.setAttributedString(
                NSAttributedString(string: text, attributes: defaultAttributes)
            )
            note.selectionLocation = 0
            if index == selectedIndex {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                updateStatus()
            } else {
                selectTab(at: index)
            }
            return
        }

        let note = Note(
            id: UUID(), fileURL: nil, untitledName: title, text: text,
            attributes: defaultAttributes, assets: store.assets
        )
        note.isScratch = true
        notes.insert(note, at: min(selectedIndex + 1, notes.count))
        selectedIndex = notes.firstIndex { $0 === note } ?? notes.count - 1
        installCurrentNote()
        refreshTabs()
        updateStatus()
        refreshImages(force: true)
        flush()
    }

    /// A name from `:w` or `:e`: `~` and an absolute path mean what they say,
    /// and anything else lands in the folder the last save used.
    private func resolvedURL(for name: String, near note: Note?) -> URL {
        let expanded = (name as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("/") else { return URL(fileURLWithPath: expanded) }
        let folder = preferences.lastSaveDirectory
            ?? note?.fileURL?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return folder.appendingPathComponent(expanded)
    }
}

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
        // The matches have moved with the edit.
        vimEngine.refreshSearchHighlights()
        scheduleImageRefresh()
        // The blocks have moved under the pane; nothing is lit again until it
        // has been rendered afresh.
        markdownPreview.invalidateBlocks()
        scheduleMarkdownPreviewRender()
        scheduleSave()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        currentNote?.selectionLocation = textView.selectedRange().location
        updateCursorPosition()
        // Moving the caret any other way retires the remembered click.
        clickedChipLocation = nil
        updateSidebarHighlight()
        highlightPreviewBlock()
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

/// What the tabs sit on, right across the window: the same paper as the
/// columns below, a hairline dividing it from them, and the whole of it
/// draggable, since it is where the title bar used to be.
private final class TabStripBackgroundView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
