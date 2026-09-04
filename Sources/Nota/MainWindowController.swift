import AppKit

/// The whole UI: a document workspace with a tab strip across its title bar,
/// an editor and optional Markdown preview between shared chrome, and a status
/// line across the bottom.
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
        /// The two document columns' floors in split, where both are on
        /// screen and the divider is the reader's to drag. In the other two
        /// modes the column that is away is held at nothing at all.
        static let editorMinimumWidth: CGFloat = 360
        static let previewMinimumWidth: CGFloat = 240
        /// How long a mode you asked for takes to slide across, and how often
        /// the slide steps while it does.
        static let previewModeSlide: TimeInterval = 0.2
        static let previewModeSlideStep: TimeInterval = 1.0 / 60
    }

    /// How far the tab strip starts from the window's leading edge: the
    /// room the traffic lights need. A tab torn off into a window of its own
    /// lands right against it, so the gesture has to know the figure.
    static let tabStripLeadingInset = Layout.trafficLightInset

    private let store: SessionStore
    private var notes: [Note] = []
    private var selectedIndex = 0

    /// How the session file gets written. The app hands in its own, which
    /// gathers every window; a controller standing on its own — a test, or
    /// the last window left — writes itself out as the whole session.
    var sessionWriter: (() -> Void)?
    /// What ⌘W means for this window, once the app has more than one. `nil`,
    /// or a handler that says no, keeps today's behaviour: flush and hide.
    /// Saying yes lets the window close for real; the handler has already
    /// found its tabs another home.
    var windowCloseHandler: ((MainWindowController) -> Bool)?

    /// A tab dragged out of the strip needs a window of its own: the
    /// registry makes one around the note, at the frame the gesture asks
    /// for. Without a handler — a controller standing on its own in a test
    /// — a tab simply cannot be torn off, and the drag does nothing.
    var tearOffHandler: ((Note, NSRect) -> MainWindowController?)?
    /// Which window a torn-off tab is hovering, so its strip can show where
    /// the tab would land. The registry asks the window server; a test
    /// answers for the windows it parked off screen itself.
    var dockTargetFinder: ((NSPoint, NSWindow) -> MainWindowController?)?
    /// How a window nobody wants any more goes away.
    var windowCloser: ((MainWindowController) -> Void)?
    /// How a window is put in front. Tests hand in one that keeps it off
    /// every display, so a run of the suite never flashes a window up.
    var windowPresenter: ((NSWindow) -> Void)?

    private var preferences: Preferences { .shared }
    private var fontSize: CGFloat { preferences.fontSize }

    private let textView: NotaTextView
    private let scrollView = FindBarScrollView()
    private var lineNumberRuler: LineNumberRulerView?
    private let tabBar = TabBarView()
    private lazy var imageSidebar = ImageSidebarView(topInset: 8)
    /// The outer split keeps the optional image sidebar outside the document.
    private let splitViewController = NSSplitViewController()
    /// The document owns the shared tab strip and the editor/preview split
    /// beneath it, so the divider begins below rather than crossing the tabs.
    private let workspacePane = NSViewController()
    private let workspaceSplitViewController = DocumentSplitViewController()
    private let editorPane = NSViewController()
    private let sidebarPane = NSViewController()
    private var sidebarItem: NSSplitViewItem?
    private let previewPane = NSViewController()
    /// The preview column itself: one host holding one content view at a time
    /// — the render for a Markdown tab, the document for a PDF, and whatever
    /// comes after them. Nothing out here knows which.
    private let previewColumn = PreviewPaneView(zenTopInset: Layout.zenTopInset)
    private var previewItem: NSSplitViewItem?
    private var editorItem: NSSplitViewItem?
    private var previewWorkItem: DispatchWorkItem?
    /// The preview's share of the document split, as the divider was last
    /// left. Read on the way out of split and pinned back on the way in.
    private var splitPreviewFraction: CGFloat = 0.5
    /// True while a mode slide is still moving. Only one is ever on the
    /// wing: a second divider animation started over a first would fight it
    /// for the same position, and the pair would land wherever they met.
    private var previewModeIsSliding = false
    /// The timer stepping the divider across, while one is stepping.
    private var previewModeSlideTimer: Timer?
    /// The split's width as of the last time the columns were arranged. A
    /// resize notification that comes with a new width is the window
    /// changing size — the columns keep their shares of it; one that comes
    /// with the same width is a drag, which is a new share to remember.
    private var lastSplitWidth: CGFloat = 0
    /// True while the divider is being put somewhere, so the resize the move
    /// itself sets off is not read back as a drag.
    private var isPlacingDivider = false
    /// Whether a drag is already waiting to be read at the end of the loop.
    private var splitFractionReadPending = false
    /// A mode asked for mid-slide, waiting for the slide to land, and how it
    /// asked to arrive — a tab switch that lands there still snaps.
    private var deferredPreviewModeSlides: Bool?
    /// Counts the slides, so the one that lands is the one that took off.
    private var previewModeSlideNumber = 0
    /// The mode the layout is actually in — the tab in front says which one
    /// it wants, zen mode says which of them it may have.
    private var installedPreviewMode: PreviewMode = .off
    /// Whether the render is on screen right now, in either of the two modes
    /// that show it.
    private var previewIsVisible: Bool { installedPreviewMode != .off }
    /// The floating mode control, once per column. In the editor mode only
    /// the editor's is up; in split each column carries its own; in reading
    /// the editor column is collapsed, so only the preview's is left. Neither
    /// takes room from the text — they hover over its top-trailing corner.
    private lazy var editorModeOverlay = ModeControlOverlay(
        target: self, action: #selector(previewModeControlChanged)
    )
    private lazy var previewModeOverlay = ModeControlOverlay(
        target: self, action: #selector(previewModeControlChanged)
    )
    private var tabBarLeading: NSLayoutConstraint?
    private var workspaceSplitTopToTabBar: NSLayoutConstraint?
    private var workspaceSplitTopToPane: NSLayoutConstraint?
    private var workspaceSplitBottomToStatus: NSLayoutConstraint?
    private var workspaceSplitBottomToPane: NSLayoutConstraint?
    private let statusSeparator = NSBox()
    private var editorTrailing: NSLayoutConstraint?

    /// Zen mode strips the window back to the text. Session only — it is
    /// never persisted, so Nota always opens with its chrome.
    private(set) var isZenMode = false
    private let zenDragRegion = DragRegionView()
    private var editorTopToContent: NSLayoutConstraint?
    private var editorTopToZenInset: NSLayoutConstraint?
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
    /// How long the content in the preview column is in its own units, when
    /// it has any — a PDF's pages. `nil` whenever the editor's own words and
    /// characters are the answer, which is what puts them back.
    private var previewStatus: PreviewFooterStatus?
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

    /// A tab that has been dragged out of this window's strip and is riding
    /// the pointer in a window of its own. It lives until the release, and
    /// the release is what decides whether that window stays.
    struct TearOff {
        let controller: MainWindowController
        /// Where the tab was in this window's strip, so Esc can put it back.
        let sourceIndex: Int
        /// Where the pointer sits inside the torn-off window.
        let pointerOffset: NSPoint
        /// Whether this window gave up its last tab to start the gesture.
        let sourceEmptied: Bool
        /// The strip the pointer is over, and the slot it would drop into.
        var dockTarget: MainWindowController?
        var dockSlot: Int?
    }

    private var tearOffGesture: TearOff?

    /// True only while AppKit is inside this window's own close, so nothing
    /// asks a window that is already going to go again.
    private(set) var isClosingWindow = false

    // MARK: - Setup

    /// `sessionWindow` is the window this controller stands for at launch:
    /// the app hands one in per window in the session file. `nil` means read
    /// the file and take the first window — the single-window path a test
    /// and a lone window take, and the only one that may prune the cache.
    /// `adopting` hands the window its notes outright, for one torn off
    /// another window.
    init(store: SessionStore,
         restoring sessionWindow: SessionWindow? = nil,
         adopting adoptedNotes: [Note] = [],
         sessionWriter: (() -> Void)? = nil) {
        self.store = store
        self.sessionWriter = sessionWriter

        // Explicit TextKit 1 stack: `replaceTextStorage` is how a tab switch
        // swaps documents, and that lives on NSLayoutManager.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        self.installedStorage = storage
        self.textView = NotaTextView(frame: .zero, textContainer: container)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = "Nota"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The tab strip lives inside the full-size title bar and owns its
        // drag gesture. Native title-bar dragging otherwise runs alongside
        // that gesture and moves the window while a tab is being reordered.
        // Empty strip space still moves the window explicitly through
        // `TabBarView.mouseDown` and `performDrag(with:)`.
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 260)
        window.delegate = self
        // Where the window sits is the session's to say, per window — one
        // autosaved frame cannot hold more than one of them.
        window.center()

        let workspace = PaneView()
        workspacePane.view = workspace
        editorPane.view = NSView()
        sidebarPane.view = NSView()
        // Keeps the thumbnails clear of the traffic lights when on the left.
        sidebarPane.view.additionalSafeAreaInsets = NSEdgeInsets(
            top: 8, left: 0, bottom: 0, right: 0
        )
        window.contentViewController = splitViewController

        buildUI()
        // The counts are re-fitted once the two side regions have their
        // frames, which is the only moment their real widths are known.
        workspace.onLayout = { [weak self] in self?.updateCountsLabel() }
        buildSidebarPane()
        buildPreviewPane()
        buildWorkspaceSplitItems()
        rebuildSplitItems()
        configureVim()

        // A window with no session window of its own is the whole session:
        // it reads the file, takes the font size from it, and is the only
        // one entitled to prune the cache — with more than one window open,
        // another window's cached text is not rubbish.
        let loaded = sessionWindow == nil && adoptedNotes.isEmpty ? store.load() : nil
        if let size = loaded?.fontSize { preferences.fontSize = CGFloat(size) }
        let restored = sessionWindow ?? loaded?.windows.first

        // Before the tabs, so the first save this window makes already has
        // the frame it came back to rather than the one it was built with.
        if let frame = restored?.frame { window.setFrame(frame.rect, display: false) }

        if adoptedNotes.isEmpty {
            restoreSession(restored, pruningCache: sessionWindow == nil)
        } else {
            adopt(adoptedNotes)
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: Preferences.didChange, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI() {
        let content = editorPane.view
        let workspace = workspacePane.view
        content.wantsLayer = true
        workspace.wantsLayer = true

        let workspaceBackground = BackgroundView()
        workspaceBackground.translatesAutoresizingMaskIntoConstraints = false
        workspace.addSubview(workspaceBackground)

        workspacePane.addChild(workspaceSplitViewController)
        let workspaceSplit = workspaceSplitViewController.view
        workspaceSplit.translatesAutoresizingMaskIntoConstraints = false
        workspace.addSubview(workspaceSplit)

        let background = BackgroundView()
        background.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(background)

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.delegate = self
        workspace.addSubview(tabBar)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.placeholderString = "Search all notes"
        searchField.delegate = self
        searchField.isHidden = true
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = false
        workspace.addSubview(searchField)
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
        scrollView.onFindBarVisibilityChange = { [weak self] _ in
            self?.updateModeControlOverlays()
        }
        content.addSubview(scrollView)

        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        lineNumberRuler = ruler
        applyLineNumberVisibility()
        applyWordWrap()

        let separator = statusSeparator
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        workspace.addSubview(separator)

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
        workspace.addSubview(statusLabel)

        modeBadge.translatesAutoresizingMaskIntoConstraints = false
        modeBadge.setMode(vimMode, animated: false)
        workspace.addSubview(modeBadge)

        // The pending keys are the badge's quiet companion, so they follow the
        // badge's type rather than the counts'.
        pendingKeysLabel.translatesAutoresizingMaskIntoConstraints = false
        pendingKeysLabel.font = .systemFont(ofSize: 11, weight: .medium)
        pendingKeysLabel.textColor = .tertiaryLabelColor
        workspace.addSubview(pendingKeysLabel)

        cursorLabel.translatesAutoresizingMaskIntoConstraints = false
        cursorLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        cursorLabel.textColor = .secondaryLabelColor
        workspace.addSubview(cursorLabel)

        zenDragRegion.translatesAutoresizingMaskIntoConstraints = false
        zenDragRegion.isHidden = true
        content.addSubview(zenDragRegion)

        // Last in, so it lies over the bottom of the document rather than
        // taking room from it: opening `:` never moves either pane.
        commandPane.translatesAutoresizingMaskIntoConstraints = false
        workspace.addSubview(commandPane)

        NSLayoutConstraint.activate([
            workspaceBackground.topAnchor.constraint(equalTo: workspace.topAnchor),
            workspaceBackground.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            workspaceBackground.trailingAnchor.constraint(equalTo: workspace.trailingAnchor),
            workspaceBackground.bottomAnchor.constraint(equalTo: workspace.bottomAnchor),

            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            tabBar.topAnchor.constraint(equalTo: workspace.topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),

            searchField.trailingAnchor.constraint(equalTo: workspace.trailingAnchor, constant: -12),
            searchField.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 220),

            workspaceSplit.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            workspaceSplit.trailingAnchor.constraint(equalTo: workspace.trailingAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),

            zenDragRegion.topAnchor.constraint(equalTo: content.topAnchor),
            zenDragRegion.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            zenDragRegion.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            zenDragRegion.heightAnchor.constraint(equalToConstant: Layout.zenTopInset),

            separator.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: workspace.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: workspace.bottomAnchor,
                                              constant: -Layout.statusBarHeight),

            modeBadge.leadingAnchor.constraint(equalTo: workspace.leadingAnchor,
                                               constant: Layout.statusInset),
            modeBadge.centerYAnchor.constraint(equalTo: separator.bottomAnchor,
                                               constant: Layout.statusBarHeight / 2),

            pendingKeysLabel.leadingAnchor.constraint(equalTo: modeBadge.trailingAnchor,
                                                      constant: 8),
            pendingKeysLabel.centerYAnchor.constraint(equalTo: modeBadge.centerYAnchor),

            cursorLabel.trailingAnchor.constraint(equalTo: workspace.trailingAnchor,
                                                  constant: -Layout.statusInset),
            cursorLabel.centerYAnchor.constraint(equalTo: modeBadge.centerYAnchor),

            statusLabel.centerYAnchor.constraint(equalTo: modeBadge.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: cursorLabel.leadingAnchor,
                                                  constant: -12),
        ])

        NSLayoutConstraint.activate([
            commandPane.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            commandPane.trailingAnchor.constraint(equalTo: workspace.trailingAnchor),
            commandPane.heightAnchor.constraint(equalToConstant: VimCommandPane.height),
        ])
        // It sits on the footer, and on the bottom of the window in zen mode,
        // where there is no footer to sit on.
        paneBottomToStatus = commandPane.bottomAnchor.constraint(
            equalTo: statusSeparator.topAnchor
        )
        paneBottomToContent = commandPane.bottomAnchor.constraint(
            equalTo: workspace.bottomAnchor
        )
        paneBottomToStatus?.isActive = true

        // Centred in the footer, but only as far as the left and right
        // regions allow — hence the yielding priority.
        let centred = statusLabel.centerXAnchor.constraint(equalTo: workspace.centerXAnchor)
        centred.priority = .defaultHigh
        centred.isActive = true

        countsLeadingToVim = statusLabel.leadingAnchor.constraint(
            greaterThanOrEqualTo: pendingKeysLabel.trailingAnchor, constant: 12
        )
        countsLeadingToEdge = statusLabel.leadingAnchor.constraint(
            greaterThanOrEqualTo: workspace.leadingAnchor, constant: Layout.statusInset
        )
        applyFooterVisibility()

        tabBarTrailingToEdge = tabBar.trailingAnchor.constraint(
            equalTo: workspace.trailingAnchor, constant: -8
        )
        tabBarTrailingToSearch = tabBar.trailingAnchor.constraint(
            equalTo: searchField.leadingAnchor, constant: -8
        )
        tabBarTrailingToEdge?.isActive = true

        tabBarLeading = tabBar.leadingAnchor.constraint(
            equalTo: workspace.leadingAnchor, constant: Layout.trafficLightInset
        )
        tabBarLeading?.isActive = true

        // A small breathing gap so the scroller never touches the pane edge
        // (or the sidebar divider).
        editorTrailing = scrollView.trailingAnchor.constraint(
            equalTo: content.trailingAnchor, constant: -Layout.editorTrailingGap
        )
        editorTrailing?.isActive = true

        workspaceSplitTopToTabBar = workspaceSplit.topAnchor.constraint(equalTo: tabBar.bottomAnchor)
        workspaceSplitTopToPane = workspaceSplit.topAnchor.constraint(equalTo: workspace.topAnchor)
        workspaceSplitBottomToStatus = workspaceSplit.bottomAnchor.constraint(
            equalTo: statusSeparator.topAnchor
        )
        workspaceSplitBottomToPane = workspaceSplit.bottomAnchor.constraint(
            equalTo: workspace.bottomAnchor
        )
        workspaceSplitTopToTabBar?.isActive = true
        workspaceSplitBottomToStatus?.isActive = true

        editorTopToContent = scrollView.topAnchor.constraint(equalTo: content.topAnchor)
        editorTopToZenInset = scrollView.topAnchor.constraint(
            equalTo: content.topAnchor, constant: Layout.zenTopInset
        )
        scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor).isActive = true
        editorTopToContent?.isActive = true

        installModeOverlay(editorModeOverlay, over: content)
        applyEditorInsets()
    }

    /// The hover band across the top of a column, laid over whatever the
    /// column is showing. It is added last so it is the topmost thing there,
    /// and it hands every click but the control's own back to what is under
    /// it.
    private func installModeOverlay(_ overlay: ModeControlOverlay, over container: NSView) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.heightAnchor.constraint(
                equalToConstant: ModeControlOverlay.hoverBandHeight
            ),
        ])
    }

    /// A segment clicked in either column's control.
    @objc private func previewModeControlChanged(_ sender: NSSegmentedControl) {
        let modes = PreviewMode.allCases
        guard modes.indices.contains(sender.selectedSegment) else { return }
        let clicked = [editorModeOverlay, previewModeOverlay]
            .first { $0.modeControl === sender }
        setPreviewMode(modes[sender.selectedSegment])
        // The pointer is still on the control that was just clicked. If that
        // column survived the mode change it stays up without waiting to be
        // entered again; if it did not, the one that took its place does, so
        // the control never blinks out from under the cursor.
        let survivor = clicked.map { $0.isHidden ? visibleModeControlOverlay : $0 }
        (survivor ?? visibleModeControlOverlay).setRevealed(true, animated: false)
    }

    private func buildSidebarPane() {
        let container = sidebarPane.view
        imageSidebar.translatesAutoresizingMaskIntoConstraints = false
        imageSidebar.assets = store.assets
        imageSidebar.delegate = self
        imageSidebar.onSettings = { [weak self] in self?.openSettings(nil) }
        container.addSubview(imageSidebar)
        NSLayoutConstraint.activate([
            imageSidebar.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            imageSidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageSidebar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageSidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func buildPreviewPane() {
        previewPane.view = previewColumn
        previewColumn.horizontalInset = previewHorizontalInset
        previewColumn.onWidthChange = { [weak self] in
            self?.schedulePreviewRefresh()
        }
        previewColumn.onBlockClick = { [weak self] source in
            self?.goToSource(source)
        }
        // ⌘F in reading mode opens a bar over the content, in the corner the
        // column's own mode control floats in.
        previewColumn.onFindBarVisibilityChange = { [weak self] _ in
            self?.updateModeControlOverlays()
        }
        // The reader moved somewhere the content is keeping — a page turned
        // in a PDF. That is where the tab is left, so it goes where a caret
        // would: into the note, and from there into the session on the same
        // debounce a keystroke uses.
        previewColumn.onPositionChange = { [weak self] position in
            self?.previewPositionDidChange(position)
        }

        installModeOverlay(previewModeOverlay, over: previewColumn)
    }

    /// The editor and preview share a split below the one document tab strip.
    /// Keeping this split inside the workspace is what stops its divider at
    /// the bottom edge of the tabs.
    private func buildWorkspaceSplitItems() {
        // Neither column ever collapses. A mode is a divider position inside
        // the width the window gives the split: the editor's whole column in
        // the editor mode, the render's whole column in reading, and the
        // remembered share of it in split. Nothing here ever asks the split
        // for a width, so nothing here can ask the window for one.
        let editor = NSSplitViewItem(viewController: editorPane)
        editor.canCollapse = false

        // A plain item, not an inspector: the preview is the note's other
        // half rather than chrome about it, so it takes the paper background
        // and an even split rather than the system's translucent material.
        let preview = NSSplitViewItem(viewController: previewPane)
        preview.canCollapse = false

        workspaceSplitViewController.addSplitViewItem(editor)
        workspaceSplitViewController.addSplitViewItem(preview)
        previewItem = preview
        editorItem = editor
        applyColumnBounds(for: installedPreviewMode)

        // A column closed to nothing must not leave a divider drawn against
        // the window's edge, nor a drag cursor over one.
        workspaceSplitViewController.hidesDivider = { [weak self] in
            self?.installedPreviewMode != .split
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(documentSplitDidResize),
            name: NSSplitView.didResizeSubviewsNotification,
            object: workspaceSplitViewController.splitView
        )
    }

    /// The split has been re-laid-out: either it has a new width — the
    /// window resized, or was laid out for the first time — and the mode is
    /// shared out against it again, or the divider moved inside a width that
    /// did not, which is a drag and a new share to remember.
    @objc private func documentSplitDidResize(_ notification: Notification) {
        guard !previewModeIsSliding, !isPlacingDivider else { return }
        let width = workspaceSplitViewController.splitView.bounds.width
        guard abs(width - lastSplitWidth) > 0.5 else {
            return scheduleSplitFractionRead()
        }
        lastSplitWidth = width
        guard width > 1 else { return }
        placeDivider(for: installedPreviewMode)
    }

    /// A drag is read at the end of the run loop rather than out of the
    /// notification. A layout pass passes through arrangements nobody asked
    /// for on its way to the one it settles on — the editor at its floor for
    /// an instant is not a divider anybody dragged there — and only where it
    /// comes to rest is a share worth remembering.
    private func scheduleSplitFractionRead() {
        guard !splitFractionReadPending else { return }
        splitFractionReadPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.splitFractionReadPending = false
            guard !self.previewModeIsSliding, !self.isPlacingDivider,
                  self.installedPreviewMode == .split else { return }
            // Where the remembered share already puts it: a placement of our
            // own settling, not a drag. Reading it back would only fold the
            // rounding into the share, over and over.
            let editor = self.workspaceSplitViewController.splitView
                .subviews.first?.frame.width ?? 0
            guard abs(editor - self.dividerPosition(for: .split)) > 1 else { return }
            self.rememberSplitFraction()
        }
    }

    /// A real sidebar item on the left, an inspector item on the right — both
    /// give the native translucent material, the full-height look under the
    /// titlebar, and animated collapsing for free. The document workspace is
    /// one sibling, regardless of whether its preview is open.
    private func rebuildSplitItems() {
        let wasCollapsed = sidebarItem?.isCollapsed ?? !sidebarIsVisible
        for item in splitViewController.splitViewItems {
            splitViewController.removeSplitViewItem(item)
        }

        let workspaceItem = NSSplitViewItem(viewController: workspacePane)
        workspaceItem.minimumThickness = 360
        workspaceItem.canCollapse = false

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

        // The images stay outermost whichever edge they are on. The preview
        // remains nested inside the document workspace beside its editor.
        if side == .left {
            splitViewController.addSplitViewItem(item)
            splitViewController.addSplitViewItem(workspaceItem)
        } else {
            splitViewController.addSplitViewItem(workspaceItem)
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
        previewColumn.horizontalInset = previewHorizontalInset
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

    /// The render's left and right margin. It has no gutter to make room for,
    /// so it is simply the setting — and zen's wider one in zen, so that with
    /// both columns on screen the two bodies of text line up.
    var previewHorizontalInset: CGFloat {
        isZenMode ? Layout.zenTextPadding : preferences.padding.inset
    }

    /// What the editor is typing with, for the tests.
    var editorParagraphStyle: NSParagraphStyle? { textView.defaultParagraphStyle }

    /// The editor column's scrolling parts, for the word-wrap tests: how wide
    /// the content is, how much of it is on screen, and what the container is
    /// tracking.
    var editorScrolling: (scrollView: NSScrollView, textView: NSTextView,
                          container: NSTextContainer?, visibleWidth: CGFloat) {
        (scrollView, textView, textView.textContainer, editorVisibleWidth)
    }

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

    /// How wide a wrapped line gets. The gutter is a ruler, and AppKit makes
    /// room for one by insetting the clip view's content rather than its
    /// frame — so the clip view's own width is the whole column, insets and
    /// all, and the text only gets what is left.
    private var editorVisibleWidth: CGFloat {
        let clip = scrollView.contentView
        let insets = clip.contentInsets
        return max(0, clip.bounds.width - insets.left - insets.right)
    }

    /// Settings → "Word wrap". On, the container is welded to the text view's
    /// width and a long line folds, which is how the editor has always
    /// behaved. Off, the container is unbounded, the text view grows to
    /// whatever the longest line measures, and the scroll view puts a
    /// horizontal scroller under it. The gutter is a ruler, so it stays
    /// pinned to the left edge either way.
    private func applyWordWrap() {
        guard let container = textView.textContainer else { return }
        let wraps = preferences.wrapsLines
        scrollView.hasHorizontalScroller = !wraps

        let visibleWidth = editorVisibleWidth
        if wraps {
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            container.widthTracksTextView = true
            container.size = NSSize(
                width: visibleWidth, height: CGFloat.greatestFiniteMagnitude
            )
            textView.minSize = NSSize(width: 0, height: 0)
            // Before the first layout there is no width to hand back, and the
            // autoresizing mask will set one as soon as there is.
            if visibleWidth > 0 {
                textView.setFrameSize(
                    NSSize(width: visibleWidth, height: textView.frame.height)
                )
            }
        } else {
            container.widthTracksTextView = false
            container.size = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.isHorizontallyResizable = true
            // The text view sizes itself to the text, so it must not also be
            // stretched to the clip view.
            textView.autoresizingMask = []
            // The floor keeps a short note filling the width it can see, so a
            // click to the right of the text still lands in it. A text view
            // that is a scroll view's document view keeps this floor level
            // with the column on its own as the window resizes — see
            // `testWordWrapKeepsAShortNoteFillingAWidenedColumn`.
            textView.minSize = NSSize(width: visibleWidth, height: 0)
        }
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        textView.layoutManager?.ensureLayout(for: container)
        textView.sizeToFit()
        lineNumberRuler?.refresh()
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
                guard let chip = value as? NotaImageAttachment else { return }
                chip.updateChip(font: font, index: number)
                number += 1
            }
            note.storage.endEditing()
        }
        applyTextAttributes()
        applyLineNumberVisibility()
        applyWordWrap()
        if preferences.sidebarSide != installedSidebarSide {
            installedSidebarSide = preferences.sidebarSide
            rebuildSplitItems()
        }
        refreshImages(force: true)
        applyPreviewMode()
        updateModeControlOverlays()
        previewColumn.invalidateRenders()
        refreshPreviewContent()
        vimEngine.isEnabled = preferences.vimMode
        applyFooterVisibility()
        updateStatus()
        scheduleSave()
    }

    // MARK: - Session restore

    private func restoreSession(_ sessionWindow: SessionWindow?, pruningCache: Bool) {
        for tab in sessionWindow?.tabs ?? [] {
            notes.append(makeRestoredNote(from: tab))
        }
        if notes.isEmpty {
            notes.append(makeUntitledNote())
        }
        normalizeUntitledNames()

        selectedIndex = sessionWindow?.selectedTabID
            .flatMap { id in notes.firstIndex { $0.id == id } } ?? 0

        if pruningCache { store.pruneCache(keeping: notes.map(\.id)) }
        finishRestore()
    }

    /// A window opened around notes that already exist — one torn off
    /// another window. Nothing is read and nothing is pruned: the notes
    /// bring their text, their undo history and their cache files with them.
    private func adopt(_ adopted: [Note]) {
        notes = adopted
        selectedIndex = 0
        finishRestore()
    }

    private func finishRestore() {
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
        // Asked before the file is read: `TextFile.read` says no to a binary,
        // and a PDF or a picture read as a note that failed would come back
        // as a dirty tab of nothing at all.
        if let fileURL, let kind = viewerKindAtRestore(fileURL) {
            return makeRestoredViewerNote(from: tab, fileURL: fileURL, kind: kind)
        }
        var text = store.readText(for: tab.id) ?? ""
        var isDirty = tab.isDirty
        // The session remembers the file's shape; only a session written
        // before Nota did has to ask the file again.
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
        // A session written before the mode was per-tab says nothing, and
        // those tabs come back in the editor.
        note.previewMode = tab.previewMode ?? .off
        return note
    }

    /// Whether a restored tab's file is one Nota views rather than edits,
    /// and which: the bytes decide when the file is still there, the same as
    /// `open(url:)` — so a session tab named `report` that is really a PDF
    /// comes back as one. Once it is not there to read at all, the name is
    /// what is left to go on, which is what keeps a missing `.pdf`'s tab a
    /// PDF tab rather than an empty, dirty text one.
    private func viewerKindAtRestore(_ url: URL) -> NoteKind? {
        switch FileSniff.classify(at: url) {
        case .pdf: NoteKind.pdf
        case .image: NoteKind.image
        case .unreadable: Note.viewerKind(url)
        case .text, .binary: nil
        }
    }

    /// A PDF or picture tab coming back. There is no cache behind it and
    /// nothing to be dirty about: the file is the whole of it, and a file
    /// that has gone keeps its tab and says so in the pane. `selection` is
    /// the page, for the one that has pages.
    private func makeRestoredViewerNote(
        from tab: SessionTab, fileURL: URL, kind: NoteKind
    ) -> Note {
        let note = Note(
            id: tab.id,
            fileURL: fileURL,
            untitledName: nil,
            text: "",
            attributes: defaultAttributes,
            assets: store.assets,
            kind: kind
        )
        note.selectionLocation = max(0, tab.selection)
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
        // keyboard does not. A PDF has no text behind it to type into either.
        textView.isEditable = note.isEditable
        vimEngine.isModifiable = note.isEditable
        // Temporary attributes belong to the layout manager, not the note, so
        // the highlights are laid on again for whatever is now in it.
        vimEngine.refreshSearchHighlights()
        applyTextAttributes()
        // A PDF tab was left on a page rather than on a character; the page
        // goes back into the pane with the document, in `updatePreviewContent`.
        if note.kind == .text {
            let location = max(0, min(note.selectionLocation, note.storage.length))
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
        }
        lineNumberRuler?.refresh()
        // The mode belongs to the tab, so switching tabs opens, splits or
        // collapses for the tab you land on. Not animated: the tab's other
        // half is simply there or not, the way its text is, rather than
        // sliding in behind the note you asked for. It comes before the
        // keyboard is handed out — in reading mode the editor is collapsed
        // and cannot take it.
        applyPreviewMode()
        updatePreviewModeControl()
        updateModeControlOverlays()
        focusForPreviewMode()
        refreshPreviewContent()
    }

    /// Also re-asks whether the tab in front is Markdown: ⌘S is where an
    /// untitled note gets a name, and a `.txt` has no mode control.
    private func refreshTabs() {
        tabBar.setItems(
            notes.map { TabBarItem(title: $0.title, isDirty: $0.isDirty) },
            selectedIndex: selectedIndex
        )
        updateModeControlOverlays()
    }

    private func updateStatus() {
        // A PDF has no words, characters, pictures or lines to speak of, and
        // neither has a picture. How long a document is, is how many pages;
        // how big a picture is, is how many pixels. The content in the column
        // is what says so, already written out; a render has nothing of its
        // own to add, and the counts stand.
        if let status = currentPreviewFooterStatus {
            previewStatus = status
        } else {
            previewStatus = nil
            let plain = currentNote?.text ?? ""
            let stripped = NoteText.strippingTokens(plain)
            counts = (
                words: TextStats.wordCount(stripped),
                characters: TextStats.characterCount(stripped),
                images: NoteText.assetIDs(in: plain).count,
                lines: TextStats.lineCount(currentNote?.storage.string ?? "")
            )
        }
        updateCountsLabel()
        updateCursorPosition()
    }

    /// Writes the longest form of the counts that fits between the two side
    /// regions, so the middle sheds a whole segment — and finally its words —
    /// rather than truncating a phrase mid-way.
    private func updateCountsLabel() {
        // A viewer's one count has nothing to shed: there is only ever the
        // one way to write it.
        let variants = previewStatus.map { [$0.summary] }
            ?? TextStats.countVariants(
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

    /// What the tab in front has to say about its own size and where you are
    /// in it, when it has anything — a PDF's pages, a picture's pixels. The
    /// note asks, not the column: which view is in front settles itself a
    /// moment later, and the footer must not be a step behind it.
    private var currentPreviewFooterStatus: PreviewFooterStatus? {
        currentNote.flatMap { previewColumn.content(for: $0).footerStatus }
    }

    /// The caret's 1-based line and column, at the right of the footer.
    private func updateCursorPosition() {
        if let status = previewStatus {
            // Nothing to be on when there is no document to be in, and
            // nowhere to be at all in a picture.
            cursorLabel.stringValue = status.position ?? ""
            return
        }
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

    /// This window's tab strip. Another window's tear-off asks it where a
    /// dropped tab would land and tells it what caret to show.
    var tabStrip: TabBarView { tabBar }

    /// Where a tab released at this point on screen would go in this
    /// window's strip — `nil` when the point is not over the strip at all.
    func dropSlot(forScreenPoint point: NSPoint) -> Int? {
        tabBar.barPoint(forScreenPoint: point).map(tabBar.dropSlot(at:))
    }

    /// Shows (or, with `nil`, clears) the insertion caret a torn-off tab
    /// hovering this window's strip draws.
    func showDropCaret(at slot: Int?) {
        tabBar.showDropCaret(at: slot)
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
        currentNote.map(rememberSelection)
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
                format: TextFileFormat = .default, kind: NoteKind = .text) {
        let note: Note
        if let fileURL {
            note = Note(id: UUID(), fileURL: fileURL, untitledName: nil,
                        text: text, attributes: defaultAttributes, assets: store.assets,
                        format: format, kind: kind)
        } else {
            note = makeUntitledNote()
        }
        notes.insert(note, at: min(selectedIndex + 1, notes.count))
        selectedIndex = notes.firstIndex { $0 === note } ?? notes.count - 1
        if note.writesToCache { store.writeText(note.text, for: note.id) }
        installCurrentNote()
        refreshTabs()
        updateStatus()
        refreshImages(force: true)
        flush()
    }

    /// A tab dragged along the strip. `index` and `newIndex` are the same
    /// indices ⌘1–9, ⌃Tab, `gt`/`gT` and `:tabn`/`:tabp` already use — all of
    /// them index `notes` directly — so once it is reordered here, every one
    /// of those follows for free.
    func moveTab(from index: Int, to newIndex: Int) {
        guard notes.indices.contains(index), notes.indices.contains(newIndex),
              index != newIndex else { return }
        // The dragged tab is usually the selected one (mouse-down selects
        // it), but handle the general case: keep pointing at whichever note
        // was selected before the move, by identity, not by index.
        let selectedNote = currentNote
        let note = notes.remove(at: index)
        notes.insert(note, at: newIndex)
        if let selectedNote {
            selectedIndex = notes.firstIndex { $0 === selectedNote } ?? selectedIndex
        }
        refreshTabs()
        flush()
    }

    /// Takes a tab out of this window without deleting its cached text and
    /// without asking about unsaved edits: the note is not going away, it is
    /// going to another window. The note carries its own storage, undo
    /// manager, selection and dirty flag, so all of that moves with it.
    ///
    /// `keepingOneTab` is what a window that stays open wants — a strip is
    /// never empty. The window whose last tab is being torn off passes
    /// false, and closes.
    func detachNote(at index: Int, keepingOneTab: Bool = true) -> Note? {
        guard notes.indices.contains(index) else { return nil }
        let note = notes[index]
        let wasSelected = index == selectedIndex
        if wasSelected { rememberSelection(note) }
        notes.remove(at: index)

        if notes.isEmpty {
            guard keepingOneTab else {
                // Nothing is in front any more. The text view is parked on an
                // empty storage so the note takes its own — and its layout —
                // away with it, ready to be installed in the next window.
                let empty = NSTextStorage()
                textView.layoutManager?.replaceTextStorage(empty)
                installedStorage = empty
                selectedIndex = 0
                refreshTabs()
                updateStatus()
                return note
            }
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
        return note
    }

    /// Puts a detached note into this window's strip. `index` is where it
    /// lands; `nil` is the end.
    func attach(_ note: Note, at index: Int? = nil, select: Bool = true) {
        let target = min(max(index ?? notes.count, 0), notes.count)
        let hadNotes = !notes.isEmpty
        notes.insert(note, at: target)
        // Two windows can each hold an `Untitled`; the one moving in takes
        // the next free name rather than doubling up in one strip.
        if note.fileURL == nil,
           notes.contains(where: { $0 !== note && $0.title == note.title }) {
            note.untitledName = UntitledNaming.nextName(
                existing: notes.filter { $0 !== note }.map(\.title)
            )
        }

        // An empty window has nothing else to show, so the arrival is what
        // goes in front whether it was asked for or not.
        if select || !hadNotes {
            selectedIndex = target
            installCurrentNote()
        } else if target <= selectedIndex {
            selectedIndex += 1
        }

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

    /// A PDF tab has nothing to save: the file on disk is the whole of it,
    /// and Nota never changed a byte. ⌘S and ⇧⌘S are simply not offered
    /// there, and `:w` says as little.
    @discardableResult
    func save(note: Note, forcePanel: Bool) -> Bool {
        guard note.kind == .text else { return false }
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
        guard note.kind == .text else { return false }
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
        // Save As can change whether this tab is Markdown at all.
        if note === currentNote {
            applyPreviewMode()
            updateModeControlOverlays()
        }
        flushAll()
        return true
    }

    private func runSavePanel(for note: Note) -> URL? {
        let panel = NSSavePanel()
        // Every text type Nota knows, and `allowsOtherFileTypes` for the ones
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
        // The bytes decide what the file is before its name gets a say: a
        // PDF opens as one, a picture as one, and text opens as text,
        // whatever any of them is called.
        switch FileSniff.classify(at: target) {
        case .pdf:
            addTab(fileURL: target, kind: .pdf)
        case .image:
            addTab(fileURL: target, kind: .image)
        case .text:
            openAsText(target)
        case .binary:
            // Not text, and none of the signatures — but a file actually
            // named for a PDF or a picture still gets a tab. PDFKit or
            // `NSImage` may yet make sense of it; if neither does, that is
            // the pane's own missing message, not this alert.
            if let kind = Note.viewerKind(target) {
                addTab(fileURL: target, kind: kind)
            } else {
                presentFailure("Couldn’t open “\(target.lastPathComponent)”.",
                               nil, detail: "Nota only opens text files.")
            }
        case .unreadable:
            // Nothing about the file could be read at all — missing, or no
            // permission — so the name is all that is left to say what it
            // was going to be.
            presentFailure("Couldn’t open “\(target.lastPathComponent)”.", nil,
                           detail: Note.viewerKind(target) != nil
                               ? nil : "Nota only opens text files.")
        }
    }

    private func openAsText(_ target: URL) {
        guard let opened = TextFile.read(at: target) else {
            presentFailure("Couldn’t open “\(target.lastPathComponent)”.",
                           nil, detail: "Nota only opens text files.")
            return
        }
        addTab(fileURL: target, text: opened.text, format: opened.format)
        // The setting is about opening files, not about restoring them: a tab
        // coming back from the session keeps the mode it was left in.
        if preferences.opensMarkdownInReadingMode, Note.supportsRenderedPreview(target) {
            setPreviewMode(.reading)
        }
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
            rememberSelection(note)
            if note.writesToCache { store.writeText(note.text, for: note.id) }
        }
        writeSessionFile()
    }

    /// Writes every tab. Used on tab switch, window close and termination.
    func flushAll() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        currentNote.map(rememberSelection)
        for note in notes where note.writesToCache { store.writeText(note.text, for: note.id) }
        writeSessionFile()
    }

    /// Where the tab is, for the session to bring it back to: the caret in a
    /// text tab, the page being read in a PDF. The caret is the text view's;
    /// the page is the pane's, and only while it is that note's document on
    /// screen — a PDF whose file has gone is left on the page it remembers
    /// rather than sent back to the first one.
    private func rememberSelection(_ note: Note) {
        // Only the column knows where a document was left; everything else is
        // read against the caret, which the editor has.
        guard let position = previewColumn.content(for: note).rememberedPosition else {
            note.selectionLocation = textView.selectedRange().location
            return
        }
        guard note === currentNote else { return }
        note.selectionLocation = position
    }

    /// This window as the session file holds it. Scratch tabs are left out
    /// of both the session file and the cache, so `:help` is gone by the
    /// next launch rather than restored as a note.
    var sessionWindow: SessionWindow {
        let saved = notes.filter { !$0.isScratch }
        return SessionWindow(
            tabs: saved.map { $0.sessionTab() },
            selectedTabID: (currentNote?.isScratch == true ? saved.first : currentNote)?.id,
            frame: window.map { SessionFrame($0.frame) }
        )
    }

    /// The app's writer knows about every window; without one this window is
    /// the whole session.
    private func writeSessionFile() {
        guard let sessionWriter else {
            store.save(SessionState(windows: [sessionWindow], fontSize: Double(fontSize)))
            return
        }
        sessionWriter()
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

    /// Whether ⌘S and ⇧⌘S mean anything on the tab in front — what the File
    /// menu greys its two items out by. A PDF is read, never written.
    var currentTabIsSavable: Bool { currentNote?.kind == .text }

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

        workspaceSplitTopToTabBar?.isActive = !enabled
        workspaceSplitTopToPane?.isActive = enabled
        workspaceSplitBottomToStatus?.isActive = !enabled
        workspaceSplitBottomToPane?.isActive = enabled
        editorTopToContent?.isActive = !enabled
        editorTopToZenInset?.isActive = enabled
        // Split survives zen, so the render column takes the same drop and
        // gets a drag band of its own rather than running to the frame.
        previewColumn.isZenMode = enabled
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

/// The editor and render's own split. Nothing about it collapses: a mode is
/// a divider position, and in two of the three modes one column is closed to
/// nothing at all. A divider against a column of no width is a line drawn on
/// the window's edge and a resize cursor over the text beside it, so both go
/// away for as long as the column is shut.
final class DocumentSplitViewController: NSSplitViewController {
    var hidesDivider: () -> Bool = { false }

    override func splitView(
        _ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int
    ) -> Bool {
        hidesDivider() || super.splitView(splitView, shouldHideDividerAt: dividerIndex)
    }

    override func splitView(
        _ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int
    ) -> NSRect {
        guard !hidesDivider() else { return .zero }
        return super.splitView(
            splitView, effectiveRect: proposedEffectiveRect,
            forDrawnRect: drawnRect, ofDividerAt: dividerIndex
        )
    }
}

/// A transparent strip that lets the window be dragged by its top edge once
/// the title bar's own chrome is gone.
final class DragRegionView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
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

    /// Whether the render is up, what whichever render is in front is
    /// showing, and which mode the tab in front is in — for the tests.
    var previewState: (isVisible: Bool, renderedText: String, mode: PreviewMode) {
        (previewIsVisible,
         (previewColumn.current as? RenderedPreviewView)?.renderedText ?? "",
         previewMode)
    }

    /// Whether a mode slide is still on the wing — for the tests, which have
    /// no other way to tell a 0.2s slide from a snap.
    var isSlidingPreviewMode: Bool { previewModeIsSliding }

    /// Whether the front tab has a preview at all. Only a saved `.md`, `.tex`
    /// or `.html` file does; every other note keeps the whole window for its
    /// source.
    var canShowRenderedPreview: Bool { currentNote?.supportsRenderedPreview ?? false }

    /// What the front tab is read through — what the View item calls itself.
    /// `nil` for a tab with no preview, where the item is disabled.
    var currentRenderedPreviewKind: RenderedPreviewKind? { currentNote?.previewKind }

    /// What the tab in front asks for — what the View menu's checkmarks say,
    /// whether or not zen is hiding the chrome at this moment. A remembered
    /// mode on a file that has no render is deliberately ignored.
    var previewMode: PreviewMode {
        guard let note = currentNote else { return .off }
        // A PDF tab has no Markdown render and no mode control, and is in
        // reading all the same: the document takes the column the way a page
        // does. Everything else needs a render before a mode means anything.
        guard note.hasPreviewContent else { return .off }
        return note.previewMode
    }

    /// Whether the render is one of the two modes that show it.
    var showsMarkdownPreview: Bool { previewMode != .off }

    /// ⇧⌘P. Editor → split → reading → editor. The mode belongs to the tab,
    /// not to the app: a Markdown note keeps it — across relaunches, through
    /// the session — while the next ⌘T opens in the editor.
    func toggleMarkdownPreview() {
        setPreviewMode(previewMode.next)
    }

    /// ⌥⇧⌘P. Straight to the render, and straight back out of it.
    func toggleReadingMode() {
        setPreviewMode(previewMode == .reading ? .off : .reading)
    }

    /// The one way the mode ever changes: the menu, ⇧⌘P, either column's
    /// control, a block click and a keystroke in reading mode all come
    /// through here.
    func setPreviewMode(_ mode: PreviewMode) {
        guard let note = currentNote, note.supportsRenderedPreview else { return }
        note.previewMode = mode
        applyPreviewMode(animated: true)
        refreshPreviewContent()
        updatePreviewModeControl()
        updateModeControlOverlays()
        flush()
        focusForPreviewMode()
    }

    /// Moves the divider to match the tab's mode.
    ///
    /// Zen has no say in it. Zen takes the chrome away — the strip, the
    /// footer, the gutter, the thumbnails, both mode controls — but the
    /// columns under it are the note, not chrome: split stays split, at the
    /// divider it was left at, and the mode is untouched on the way back out.
    ///
    /// Only a mode switch you asked for slides. A tab switch, a note being
    /// installed or a Save As that changes whether the tab is Markdown at all
    /// simply lay out for what is in front of you, the way the tab's text
    /// simply appears rather than sliding in behind it.
    private func applyPreviewMode(animated: Bool = false) {
        let mode = previewMode
        guard mode != installedPreviewMode else { return }
        // Everything that is not the columns' width settles at once, before a
        // single frame is drawn: what the click on the page means, what the
        // keyboard belongs to, and whether a band is lit are all true of the
        // mode itself, not of the motion into it.
        previewColumn.takesKeyboard = mode == .reading
        // Reading is for reading: a click on the page stays on the page.
        previewColumn.sendsBlockClicks = mode != .reading
        // And the page is read on its own: the caret is not on screen, so
        // nothing on it is lit for the caret. Whatever split left burning
        // goes out on the way in.
        if mode == .reading { previewColumn.clearHighlight() }

        // A second slide started over a first would fight it for the same
        // divider, and the two would land wherever they met. So a mode asked
        // for mid-slide is only written down here; the slide applies it as it
        // lands, and a key held on ⇧⌘P arrives as two slides rather than
        // twenty.
        guard !previewModeIsSliding else {
            deferredPreviewModeSlides = (deferredPreviewModeSlides ?? true) && animated
            return
        }
        // Where the divider was left — read while the columns are standing
        // still, and before the mode it belongs to is replaced.
        if installedPreviewMode == .split { rememberSplitFraction() }
        installedPreviewMode = mode

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Nothing to animate — a layout you did not ask to watch, Reduce
        // Motion, or a window nobody is looking at, which is every window a
        // test makes. The divider is simply where the mode says it is, and it
        // is put there now rather than at the end of the run loop, so the
        // render that follows is made once, at the width it will be read at.
        guard animated, let window, window.isVisible, !reduceMotion else {
            placeDivider(for: mode)
            previewColumn.thawWidth()
            updateModeControlOverlays()
            return
        }

        // The render on screen is the one that slides: it is made now, at the
        // width it is leaving, so the animation itself has no work in it — no
        // render, no forced layout, nothing per frame.
        previewModeIsSliding = true
        refreshPreviewContent()
        // The render rides the animation at the width it was made for, rather
        // than re-wrapping itself on every frame of it.
        _ = previewColumn.freezeWidth()
        previewModeSlideNumber += 1
        let slide = previewModeSlideNumber
        slideDivider(to: mode) { [weak self] in self?.previewModeSlideDidLand(slide) }
    }

    /// The divider has arrived. The render is free to wrap to the width it
    /// found, the mode's own bounds go back on so the drag is what the mode
    /// allows, and anything asked for while the slide was moving happens now.
    private func previewModeSlideDidLand(_ slide: Int) {
        guard previewModeIsSliding, slide == previewModeSlideNumber else { return }
        previewModeIsSliding = false
        applyColumnBounds(for: installedPreviewMode)
        window?.layoutIfNeeded()
        lastSplitWidth = workspaceSplitViewController.splitView.bounds.width
        previewColumn.thawWidth()
        // Only now is there a final width to fit a picture or a rule to, and
        // only a render that depends on one is made again — for a plain note
        // the key still matches and nothing happens here at all.
        refreshPreviewContent()
        updateModeControlOverlays()
        let slides = deferredPreviewModeSlides
        deferredPreviewModeSlides = nil
        if let slides { applyPreviewMode(animated: slides) }
    }

    /// The divider, straight to where the mode wants it. Used for everything
    /// that is not a mode switch you watched: a tab switch, a session
    /// restore, a window that is not on screen, Reduce Motion, and a window
    /// resize that has to keep split's share of a new width.
    private func placeDivider(for mode: PreviewMode) {
        let split = workspaceSplitViewController.splitView
        // Every layout the placement sets off is the placement's own, not a
        // drag: none of it is a new share to remember.
        isPlacingDivider = true
        defer { isPlacingDivider = false }
        workspaceSplitViewController.view.layoutSubtreeIfNeeded()
        guard splitColumnRoom > 1 else {
            // A mode restored with the session arrives before the window has
            // ever been laid out. There is no room to share out yet; the
            // bounds alone say what the mode is, and the first layout pass
            // arranges the columns against them.
            applyColumnBounds(for: mode)
            return
        }
        setDividerPosition(dividerPosition(for: mode))
        applyColumnBounds(for: mode)
        workspaceSplitViewController.view.layoutSubtreeIfNeeded()
        lastSplitWidth = split.bounds.width
    }

    /// The 0.2s slide, stepped by hand. `NSSplitViewItem`'s own animator
    /// tweens a collapse, and a collapse is what used to take the window with
    /// it; a divider walked across on a timer asks the split for nothing at
    /// all, and the window is never in the conversation.
    private func slideDivider(to mode: PreviewMode, then land: @escaping () -> Void) {
        let split = workspaceSplitViewController.splitView
        workspaceSplitViewController.view.layoutSubtreeIfNeeded()
        guard splitColumnRoom > 1 else {
            placeDivider(for: mode)
            return land()
        }
        let from = split.subviews.first?.frame.width ?? 0
        let to = dividerPosition(for: mode)
        let began = Date()
        previewModeSlideTimer?.invalidate()

        // The frames, while they come. A window in the background has its
        // timers coalesced to a handful a second, so this is what the slide
        // looks like, never how long it takes.
        let timer = Timer(
            timeInterval: Layout.previewModeSlideStep, repeats: true
        ) { [weak self] timer in
            guard let self, self.previewModeSlideTimer === timer else {
                return timer.invalidate()
            }
            let t = min(max(Date().timeIntervalSince(began) / Layout.previewModeSlide, 0), 1)
            guard t < 1 else { return self.finishSlide(at: to, then: land) }
            // Ease in, ease out — the same shape AppKit's own default gives.
            self.setDividerPosition(from + (to - from) * CGFloat(t * t * (3 - 2 * t)))
        }
        RunLoop.main.add(timer, forMode: .common)
        previewModeSlideTimer = timer

        // And how long it takes. The mode is 0.2s away whether or not there
        // was a frame to spare for it: the deadline lands the slide, and a
        // slide that has already landed ignores it.
        DispatchQueue.main.asyncAfter(deadline: .now() + Layout.previewModeSlide) {
            [weak self] in
            guard let self, self.previewModeSlideTimer === timer else { return }
            self.finishSlide(at: to, then: land)
        }
    }

    /// The last frame of a slide: the divider is exactly where the mode wants
    /// it, and the mode is what the layout is in.
    private func finishSlide(at position: CGFloat, then land: () -> Void) {
        previewModeSlideTimer?.invalidate()
        previewModeSlideTimer = nil
        setDividerPosition(position)
        land()
    }

    /// Puts the divider at a position, with the columns unbounded while it
    /// travels — a floor left over from the mode being left would otherwise
    /// stop it short of the one being entered. The move re-lays the split
    /// out, and that arrives back as a resize; the flag is what keeps it from
    /// being read as a drag.
    private func setDividerPosition(_ position: CGFloat) {
        let wasPlacing = isPlacingDivider
        isPlacingDivider = true
        defer { isPlacingDivider = wasPlacing }
        applyColumnBounds(for: nil)
        workspaceSplitViewController.splitView.setPosition(position, ofDividerAt: 0)
    }

    /// Where the divider sits in each mode, measured from the leading edge —
    /// which is the editor column's width. The editor mode gives the editor
    /// all of the room, reading gives the render all of it, and split shares
    /// it out at the fraction the divider was left at, inside the floors.
    private func dividerPosition(for mode: PreviewMode) -> CGFloat {
        let room = splitColumnRoom
        switch mode {
        case .off: return room
        case .reading: return 0
        case .split:
            let floors = splitFloors
            let preview = min(
                max((room * splitPreviewFraction).rounded(), floors.preview),
                room - floors.editor
            )
            return room - preview
        }
    }

    /// What each column may be dragged to in a given mode. In split both are
    /// bounded below and neither above, so the divider moves through the
    /// whole range the two floors leave. In the other two the column that is
    /// away is held at exactly nothing — no floor, no width, no divider to
    /// drag — and the one on screen takes everything. `nil` is the slide
    /// itself: no bounds at all, so the divider can be anywhere on its way.
    private func applyColumnBounds(for mode: PreviewMode?) {
        guard let editorItem, let previewItem else { return }
        switch mode {
        case nil:
            open(editorItem, floor: 0)
            open(previewItem, floor: 0)
        case .off:
            open(editorItem, floor: 0)
            close(previewItem)
        case .reading:
            close(editorItem)
            open(previewItem, floor: 0)
        case .split:
            let floors = splitFloors
            open(editorItem, floor: floors.editor)
            open(previewItem, floor: floors.preview)
        }
    }

    /// Bounded below and open above: the other column's floor is the far end
    /// of the drag, so neither ever needs a ceiling of its own.
    private func open(_ item: NSSplitViewItem, floor: CGFloat) {
        item.minimumThickness = floor
        item.maximumThickness = NSSplitViewItem.unspecifiedDimension
    }

    /// Shut: no width at all, and no way to drag one back.
    private func close(_ item: NSSplitViewItem) {
        item.minimumThickness = 0
        item.maximumThickness = 0
    }

    /// The floors split holds its two columns to. They are required
    /// constraints, and two required floors adding up to more than the window
    /// has is a window that grows to hold them — so in a window too narrow
    /// for both they are scaled down together rather than asked for.
    private var splitFloors: (editor: CGFloat, preview: CGFloat) {
        let wanted = Layout.editorMinimumWidth + Layout.previewMinimumWidth
        let room = splitColumnRoom
        guard room > 1, room < wanted else {
            return (Layout.editorMinimumWidth, Layout.previewMinimumWidth)
        }
        let scale = room / wanted
        return (
            (Layout.editorMinimumWidth * scale).rounded(.down),
            (Layout.previewMinimumWidth * scale).rounded(.down)
        )
    }

    /// What the two columns have between them: the split less the divider
    /// they share. Sharing out the full width leaves the divider no room of
    /// its own, and a pt over is a pt somebody has to find.
    private var splitColumnRoom: CGFloat {
        let split = workspaceSplitViewController.splitView
        return split.bounds.width - split.dividerThickness
    }

    /// The preview's share of the split, taken while both columns are on
    /// screen and standing still.
    private func rememberSplitFraction() {
        let split = workspaceSplitViewController.splitView
        let total = splitColumnRoom
        guard total > 1, split.subviews.count >= 2 else { return }
        let previewWidth = split.subviews[1].frame.width
        guard previewWidth > 1 else { return }
        splitPreviewFraction = min(max(previewWidth / total, 0.01), 0.99)
    }

    /// The render is read, not typed in — so the keyboard stays in the editor,
    /// except in reading mode, where the editor is not on screen to hold it.
    private func focusForPreviewMode() {
        guard installedPreviewMode == .reading else { return focusEditor() }
        // Whatever the tab in front is read through, brought forward first:
        // the keyboard cannot go to a view that is still behind another.
        let content = currentNote.map(previewColumn.bringForward) ?? previewColumn.current
        content.focus(in: window)
    }

    /// The tab in front, as much of it as a test can otherwise not reach:
    /// what kind of thing it is holding, whether it has edits its file does
    /// not, and where it was left.
    var currentTabState: (kind: NoteKind, isDirty: Bool, selection: Int) {
        let note = currentNote
        return (note?.kind ?? .text, note?.isDirty ?? false, note?.selectionLocation ?? 0)
    }

    /// The preview column's content views and which of them is on screen —
    /// for the tests. Exactly one is ever showing, and a PDF tab is the only
    /// thing that puts the document there.
    var previewPanes: PreviewPaneView.Panes { previewColumn.panes }

    /// Both overlays, for the tests: the editor column's and the preview
    /// column's. Split has both up, one per column; the editor mode has only
    /// the first, reading only the second.
    var modeControlOverlays: (editor: ModeControlOverlay, preview: ModeControlOverlay) {
        (editorModeOverlay, previewModeOverlay)
    }

    /// The overlay the mode control is reached through. The editor column's
    /// while there is one on screen; in reading that column is collapsed, so
    /// the preview column's is the only one left.
    var visibleModeControlOverlay: ModeControlOverlay {
        installedPreviewMode == .reading ? previewModeOverlay : editorModeOverlay
    }

    /// The control in that overlay. The two are kept in step, so either
    /// answers for the other; this is the one the reader reaches first, which
    /// is what a test asking about the layout wants.
    var previewModeControl: NSSegmentedControl { visibleModeControlOverlay.modeControl }

    /// Both overlays' controls follow the tab in front — a tab switch, ⇧⌘P, a
    /// block click, a keystroke in reading mode, a restored session. The tints
    /// go with the selection: the idle segments are the quiet ones.
    private func updatePreviewModeControl() {
        let index = PreviewMode.allCases.firstIndex(of: previewMode) ?? 0
        // The tints are six symbol images built from scratch, so they are
        // laid on only when the selection has actually moved — a control
        // already showing this mode is left alone.
        for overlay in [editorModeOverlay, previewModeOverlay]
        where overlay.modeControl.selectedSegment != index {
            overlay.modeControl.selectedSegment = index
            overlay.applySegmentTints()
        }
    }

    /// Which columns carry a control. Only a tab with a render has one at
    /// all, and zen has none. Beyond that it is simply whether the column is
    /// on screen: the editor's goes in reading, the preview's is there in
    /// split and reading. Either column's ⌘F bar takes its own control away
    /// while it is up — the bar opens above the content, right where the
    /// control floats, and its own buttons must stay clickable.
    fileprivate func updateModeControlOverlays() {
        let available = canShowRenderedPreview && !isZenMode
        editorModeOverlay.setAvailable(
            available && installedPreviewMode != .reading && !scrollView.isFindBarVisible
        )
        previewModeOverlay.setAvailable(
            available && installedPreviewMode != .off && !previewColumn.current.isFindBarVisible
        )
    }

    /// Debounced, like the cache write: a burst of keystrokes re-renders once,
    /// about 150 ms after the typing stops.
    private func schedulePreviewRefresh() {
        guard previewIsVisible else { return }
        previewWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refreshPreviewContent() }
        previewWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    /// Hands the front tab to the preview column, which brings the view that
    /// tab is read through forward and shows the note in it.
    ///
    /// Which view that is, is the tab's business rather than the mode's —
    /// switching from a `.md` tab in reading to a PDF never moves the divider,
    /// so the swap cannot live in `applyPreviewMode`. What showing costs is
    /// the content's own business: a render already holding this note at this
    /// width does nothing at all here.
    private func refreshPreviewContent() {
        previewWorkItem?.cancel()
        previewWorkItem = nil
        guard let note = currentNote else { return }
        previewColumn.show(note, in: PreviewContext(
            font: preferences.font(),
            assets: store.assets,
            isVisible: previewIsVisible
        ))
        highlightPreviewBlock()
    }

    /// The reader moved somewhere the content in the column is keeping — a
    /// page turned in a PDF. That is where the tab is left, so it goes where a
    /// caret would: into the note, and from there into the session on the same
    /// debounce a keystroke uses.
    private func previewPositionDidChange(_ position: Int) {
        guard let note = currentNote else { return }
        note.selectionLocation = position
        updateCursorPosition()
        scheduleSave()
    }

    /// Lights the block the caret is in. Called on every selection change, so
    /// walking the note in the editor walks the pane beside it.
    fileprivate func highlightPreviewBlock() {
        // Split only. In the editor mode there is no render to light, and in
        // reading there is no editor on screen for a band to be pointing at:
        // the page is read on its own, so nothing on it is ever lit.
        guard installedPreviewMode == .split else { return }
        previewColumn.current.highlightBlock(containingSource: textView.selectedRange().location)
    }

    /// A block was clicked in the pane: put the caret on the first character
    /// of the source it came from and show it.
    private func goToSource(_ source: NSRange) {
        guard let note = currentNote else { return }
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
            guard let chip = value as? NotaImageAttachment else { return }
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
            if value is NotaImageAttachment { locations.append(range.location) }
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
        guard let note = currentNote, note.kind == .text else { return false }
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

    func tabBarDidRequestNewTab(_ bar: TabBarView) {
        newTab()
    }

    func tabBar(_ bar: TabBarView, didMove index: Int, to newIndex: Int) {
        moveTab(from: index, to: newIndex)
    }

    // MARK: Tear-off

    /// The tab has left the strip: it gets a window of its own, sized like
    /// this one and placed so the tab is exactly where the pointer left it.
    /// The gesture is still running in this window's tab view, so this
    /// window stays alive until the release, even when it has nothing left
    /// to show.
    func tabBar(_ bar: TabBarView, tearOff index: Int, grabOffset: NSPoint, screenPoint: NSPoint) {
        guard tearOffGesture == nil, let window, notes.indices.contains(index) else { return }
        let wasLastTab = notes.count == 1
        guard let note = detachNote(at: index, keepingOneTab: !wasLastTab) else { return }

        // Where the pointer sits inside the window it is about to hold: the
        // strip starts after the traffic lights, the torn tab is the first
        // one in it, and the strip's middle is the height it is grabbed at.
        let size = window.frame.size
        let pointerOffset = NSPoint(
            x: Self.tabStripLeadingInset + grabOffset.x,
            y: size.height - TabBarView.height / 2
        )
        let frame = NSRect(origin: originForPointer(screenPoint, offset: pointerOffset), size: size)

        guard let torn = tearOffHandler?(note, frame) else {
            // Nowhere to put it: the tab goes straight back where it was.
            attach(note, at: index, select: true)
            return
        }
        torn.windowPresenter = windowPresenter
        if let tornWindow = torn.window { present(tornWindow) }
        if wasLastTab { window.orderOut(nil) }

        tearOffGesture = TearOff(
            controller: torn, sourceIndex: index,
            pointerOffset: pointerOffset, sourceEmptied: wasLastTab
        )
    }

    /// The torn-off window follows the pointer one to one, and whichever
    /// strip is under the pointer shows where the tab would drop.
    func tabBarDragMoved(_ bar: TabBarView, to screenPoint: NSPoint) {
        guard var state = tearOffGesture, let tornWindow = state.controller.window else { return }
        tornWindow.setFrameOrigin(originForPointer(screenPoint, offset: state.pointerOffset))

        let target = dockTargetFinder?(screenPoint, tornWindow)
        let slot = target?.dropSlot(forScreenPoint: screenPoint)
        if let previous = state.dockTarget, previous !== target || slot == nil {
            previous.showDropCaret(at: nil)
        }
        state.dockTarget = slot == nil ? nil : target
        state.dockSlot = slot
        if let slot { target?.showDropCaret(at: slot) }
        tearOffGesture = state
    }

    /// Mouse-up drops the tab — into the strip under it, or nowhere, which
    /// leaves the new window standing where it is. Esc undoes the whole
    /// gesture: the tab goes home and the extra window never happened.
    func tabBarDragEnded(_ bar: TabBarView, committed: Bool, at screenPoint: NSPoint) {
        guard let state = tearOffGesture else { return }
        tearOffGesture = nil
        state.dockTarget?.showDropCaret(at: nil)

        guard committed else {
            if let note = state.controller.detachNote(at: 0, keepingOneTab: false) {
                attach(note, at: state.sourceIndex, select: true)
            }
            if state.sourceEmptied, let window { present(window) }
            windowCloser?(state.controller)
            return
        }

        if let target = state.dockTarget,
           let note = state.controller.detachNote(at: 0, keepingOneTab: false) {
            target.attach(note, at: state.dockSlot, select: true)
            if let window = target.window { present(window) }
            windowCloser?(state.controller)
        }

        // The window that gave up its last tab and got nothing back has
        // nothing left to be.
        if notes.isEmpty { windowCloser?(self) }
    }

    /// The window origin that puts `offset` — a point in the window's own
    /// coordinates — under the pointer.
    private func originForPointer(_ screenPoint: NSPoint, offset: NSPoint) -> NSPoint {
        NSPoint(x: screenPoint.x - offset.x, y: screenPoint.y - offset.y)
    }

    private func present(_ window: NSWindow) {
        guard let windowPresenter else { return window.makeKeyAndOrderFront(nil) }
        windowPresenter(window)
    }
}

extension MainWindowController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let note = currentNote else { return }
        if !note.isDirty {
            note.isDirty = true
            refreshTabs()
        }
        rememberSelection(note)
        updateStatus()
        // The matches have moved with the edit.
        vimEngine.refreshSearchHighlights()
        scheduleImageRefresh()
        // The blocks have moved under the pane; nothing is lit again until it
        // has been rendered afresh.
        previewColumn.content(for: note).invalidateBlocks()
        schedulePreviewRefresh()
        scheduleSave()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        currentNote.map(rememberSelection)
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
    /// With one window open, closing it only hides it — the window is a view
    /// onto the cache, not the app. With more than one, the app's handler
    /// hands this window's tabs to another one and lets it close for real.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        flushAll()
        isClosingWindow = true
        defer { isClosingWindow = false }
        if windowCloseHandler?(self) == true { return true }
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

// MARK: - Quick Look

/// The Quick Look panel's responder hooks live in `ImageOpening.swift`, next
/// to the rest of the Markup path; these two are what they reach through, and
/// they are here because the sidebar and the remembered render are private to
/// this file.
extension MainWindowController {

    var quickLookSidebar: ImageSidebarView { imageSidebar }

    /// Markup wrote a new picture into an asset file. The store's decoded
    /// image is already gone; the render on screen was made from it, so that
    /// has to go too.
    func assetDidChangeOnDisk() {
        previewColumn.invalidateRenders()
        schedulePreviewRefresh()
        updateSidebarHighlight()
    }
}
