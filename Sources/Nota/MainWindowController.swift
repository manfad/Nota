import AppKit

/// The whole UI: a document workspace with a tab strip across its title bar,
/// an editor and optional Markdown preview between shared chrome, and a status
/// line across the bottom.
///
/// There is a single `NSTextView`; switching tabs swaps that note's
/// `NSTextStorage` and `UndoManager` into it, which is what keeps undo from
/// bleeding between tabs.
final class MainWindowController: NSWindowController, NSUserInterfaceValidations {

    private enum Layout {
        static let trafficLightInset: CGFloat = 82
        static let textPadding: CGFloat = 20
        static let textPaddingVertical: CGFloat = 14
        static let statusInset: CGFloat = 16
        static let editorTrailingGap: CGFloat = 4
        static let statusBarHeight: CGFloat = 26
        /// The band along the top of the window an auto-hiding strip
        /// watches for the pointer.
        static let zenTopInset: CGFloat = 28
        /// With the strip gone the document runs to the very top of the
        /// window — nothing is held back for the traffic lights, which are
        /// gone too — and this thin band over the editor's own padding is
        /// what the window is still dragged by.
        static let hiddenStripDragBand: CGFloat = 12
        /// How long an auto-hidden strip takes to slide in or out, and how
        /// long it waits after the pointer leaves before it starts.
        static let tabBarOverlaySlide: TimeInterval = 0.15
        static let tabBarOverlayGrace: TimeInterval = 0.3
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
    ///
    /// Kept for tests, which run with the lights shown. Live code reads
    /// `currentTabStripLeadingInset` instead, since hiding the lights or
    /// showing a left sidebar moves the strip.
    static let tabStripLeadingInset = Layout.trafficLightInset

    /// Where the strip actually starts right now: 12pt beside a left
    /// sidebar or with the traffic lights hidden, `Layout.trafficLightInset`
    /// otherwise. A tear-off reads this so the torn tab lands under the
    /// pointer whichever inset was in effect.
    private var currentTabStripLeadingInset: CGFloat {
        tabBarLeading?.constant ?? Layout.trafficLightInset
    }

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

    /// The app's bookmarks (SPEC Todo 13). The registry hands every window
    /// the one list, so a file bookmarked here is bookmarked everywhere; a
    /// controller standing on its own gets one of its own, read from and
    /// written back to the session file it owns.
    var bookmarks = Bookmarks() {
        didSet {
            observeBookmarks()
            refreshTabs()
        }
    }

    /// Where a save with no file of its own gets one. The real panel unless
    /// a test hands in something else — `nil` from it is the panel being
    /// cancelled, which is the case ⌘D on an untitled note turns on.
    var savePanelProvider: ((Note) -> URL?)?

    /// The export sheet, asked what the reader chose. The real sheet unless
    /// a test hands in something else — `nil` from it is Cancel, and nothing
    /// is written.
    var exportSheetProvider: ((Note, [ExportTarget]) -> ExportChoice?)?

    private var preferences: Preferences { .shared }
    private var fontSize: CGFloat { preferences.fontSize }

    private let textView: NotaTextView
    private let scrollView = NSScrollView()

    /// The editor's own ⌘F bar, floating in the top-trailing corner of the
    /// editor column — the corner the mode control floats in, which the bar
    /// takes for as long as it is up.
    private let findBar = FindBarView()
    private lazy var findSession = TextFindSession(bar: findBar, textView: textView)
    /// ⌘J's pill, sharing that corner with the find bar: one or the other, and
    /// opening either sends the other away.
    private let goToLinePill = GoToLinePill()
    private lazy var goToLineSession = GoToLineSession(
        pill: goToLinePill, textView: textView
    )
    /// The one field editor the window hands every pill's fields, so ⌘G typed
    /// in one of them is the same ⌘G as everywhere else — see
    /// `PillFieldEditor`.
    private lazy var pillFieldEditor: PillFieldEditor = {
        let editor = PillFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()
    /// The offer a dirty tab whose file has changed under it gets: Reload, or
    /// Keep mine. It stands in the editor column's bottom-trailing corner, so
    /// it never has to argue with ⌘F and ⌘J for the other one.
    private let externalChangePill = ExternalChangePill()
    /// "Looks like JSON" — the offer a tab with no preview makes when its
    /// text turns out to read as something. The same corner as the reload
    /// offer, and never up at the same time as it.
    private let formatOfferPill = FormatOfferPill()
    /// The look that is waiting for the typing to stop, if one is.
    private var formatOfferWorkItem: DispatchWorkItem?
    /// Fired once a watched file's change has been dealt with — reloaded, or
    /// marked and offered. The tests wait on it; nothing in the app sets it.
    var onExternalChangeForTesting: (() -> Void)?
    /// Stands in for the real save-changes alert so a dirty-tab close can be
    /// driven without putting a modal on screen. Nothing in the app sets it.
    var confirmDiscardOverrideForTesting: (() -> NSApplication.ModalResponse)?
    /// Stands in for the save panel's "already exists, replace?" alert, the
    /// same way `confirmDiscardOverrideForTesting` stands in for the
    /// save-changes one — so a test that drives the panel past a name that
    /// collides with a real file never puts a modal on screen. Nothing in
    /// the app sets it. The `URL` is the file the write would overwrite.
    var confirmReplaceOverrideForTesting: ((URL) -> Bool)?
    private var lineNumberRuler: LineNumberRulerView?
    private let tabBar = TabBarView()
    private lazy var imageSidebar = ImageSidebarView(topInset: 8)
    /// The same column, showing a book's own table of contents instead, while
    /// a book is in front.
    private lazy var contentsSidebar = ContentsSidebarView(topInset: 8)
    /// And the same column again, showing a document's pages, while a PDF is.
    /// Exactly one of the three is on screen.
    private lazy var pageListSidebar = PageListSidebarView(topInset: 8)
    /// The outer split keeps the optional sidebar outside the document.
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
    private let previewColumn = PreviewPaneView(dragBandHeight: Layout.hiddenStripDragBand)
    private var previewItem: NSSplitViewItem?
    private var editorItem: NSSplitViewItem?
    private var previewWorkItem: DispatchWorkItem?
    /// The find bar's own re-scan after an edit, while one is waiting.
    private var findRefreshWorkItem: DispatchWorkItem?
    /// The corner action's re-parse after an edit, while one is waiting.
    /// Same beat as the footer's counts.
    private var formatSlotWorkItem: DispatchWorkItem?
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
    /// Whether the editor's text container is being held at the width it is
    /// leaving for the length of a preview-mode slide — see
    /// `freezeEditorWrapWidth()`.
    private var editorWrapWidthIsFrozen = false
    /// True only while a tab is being swapped into the editor and the
    /// selection is being put down for it — see `installCurrentNote`.
    private var isSwappingNote = false
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
    /// The strip's top edge. Normally pinned to the top of the workspace;
    /// an auto-hidden strip rides it up by its own height and back down.
    private var tabBarTop: NSLayoutConstraint?
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
    /// The band at the very top of the window an auto-hidden strip waits
    /// behind: nothing to see and nothing to click, only a tracking area.
    private let tabBarHotZone = TabBarHotZoneView()
    /// Whether the auto-hidden strip is currently lying over the split.
    private var isTabBarOverlayVisible = false
    /// The grace period between the pointer leaving the strip and the strip
    /// sliding away, cancelled the moment the pointer comes back.
    private var tabBarOverlayHideTimer: Timer?
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

    /// The footer, lualine style: the vim badge and its pending keys on the
    /// left, the counts centred, the caret's line:col on the right.
    private let statusLabel = NSTextField(labelWithString: "")
    private let modeBadge = VimModeBadge()
    private let pendingKeysLabel = NSTextField(labelWithString: "")
    private let cursorLabel = NSTextField(labelWithString: "")
    /// A text note's shape, at the right of the counts and left of the
    /// caret position: `UTF-8 ·` and `LF`, two clickable halves rather than
    /// one label, each popping its own menu. Empty over a PDF or a picture,
    /// which has no encoding or line endings to speak of.
    private let formatEncodingLabel = FooterMenuLabel()
    private let formatLineEndingLabel = FooterMenuLabel()
    /// What the tab is read as — `MD`, `JSON`, `Plain` — ahead of
    /// the encoding, so the row reads format · encoding · line ending ·
    /// cursor: what the text *is*, then how it is written down, then where
    /// the caret is in it. Its menu is the one place an untitled note or a
    /// `.txt` ever gets a preview.
    private let formatKindLabel = FooterMenuLabel()
    private lazy var footerTrailingStack = NSStackView(
        views: [formatKindLabel, formatEncodingLabel, formatLineEndingLabel, cursorLabel]
    )
    private var countsLeadingToVim: NSLayoutConstraint?
    private var countsLeadingToEdge: NSLayoutConstraint?
    private var vimMode: VimMode = .normal
    /// The four numbers behind the middle label, kept so a relayout can
    /// re-fit the text without walking the note again.
    private var counts = (words: 0, characters: 0, images: 0, lines: 1)
    /// Ticked over total task items, for a `.md` that has any. `nil` for
    /// every other tab and for a `.md` with none — the footer says nothing
    /// about tasks where there are no tasks.
    private var taskCounts: (done: Int, total: Int)?
    /// The counting job for a big note, and the number that says which one is
    /// current — an answer from an older job is thrown away rather than shown.
    private var wordCountWorkItem: DispatchWorkItem?
    private var wordCountGeneration = 0
    /// The text a file was just opened from, kept only until the first count
    /// has taken it.
    private var openedText: (id: UUID, text: String)?
    /// Where a big note's cache write goes. Serial on purpose: the writes
    /// have to land in the order they were asked for, or a pause in the
    /// typing could leave an older text on disk than the one before it.
    private let cacheWrites = DispatchQueue(label: "com.nota.cache-write", qos: .utility)
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
        LaunchTiming.mark("init: stored properties built")
        self.store = store
        self.sessionWriter = sessionWriter

        // Explicit TextKit 1 stack: `replaceTextStorage` is how a tab switch
        // swaps documents, and that lives on NSLayoutManager.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        // A 100 MB log has millions of glyphs a screen will never show. Without
        // this, `usedRect(for:)` — which sizing the text view and scrolling
        // both lean on — lays out the whole document just to answer; with it,
        // the height past what has been laid out is an estimate that firms up
        // as scrolling brings more of the document into view.
        layoutManager.allowsNonContiguousLayout = true
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

        LaunchTiming.mark("init: NSWindow made")
        let workspace = PaneView()
        workspacePane.view = workspace
        editorPane.view = NSView()
        sidebarPane.view = NSView()
        // Keeps the thumbnails clear of the traffic lights when on the left.
        sidebarPane.view.additionalSafeAreaInsets = NSEdgeInsets(
            top: 8, left: 0, bottom: 0, right: 0
        )
        window.contentViewController = splitViewController

        LaunchTiming.mark("init: window + text stack")
        buildUI()
        LaunchTiming.mark("init: buildUI")
        // The counts are re-fitted once the two side regions have their
        // frames, which is the only moment their real widths are known.
        workspace.onLayout = { [weak self] in self?.updateCountsLabel() }
        buildSidebarPane()
        LaunchTiming.mark("init: buildSidebarPane")
        buildPreviewPane()
        LaunchTiming.mark("init: buildPreviewPane")
        buildWorkspaceSplitItems()
        rebuildSplitItems()
        LaunchTiming.mark("init: split items")
        configureVim()
        LaunchTiming.mark("init: configureVim")

        // A window with no session window of its own is the whole session:
        // it reads the file, takes the font size from it, and is the only
        // one entitled to prune the cache — with more than one window open,
        // another window's cached text is not rubbish.
        let loaded = sessionWindow == nil && adoptedNotes.isEmpty ? store.load() : nil
        if let size = loaded?.fontSize { preferences.fontSize = CGFloat(size) }
        if let saved = loaded?.bookmarks { bookmarks.replace(with: saved) }
        let restored = sessionWindow ?? loaded?.windows.first

        // Before the tabs, so the first save this window makes already has
        // the frame it came back to rather than the one it was built with.
        if let frame = restored?.frame { window.setFrame(frame.rect, display: false) }

        LaunchTiming.mark("window views built")
        if adoptedNotes.isEmpty {
            restoreSession(restored, pruningCache: sessionWindow == nil)
        } else {
            adopt(adoptedNotes)
        }
        LaunchTiming.mark("window tabs restored")

        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: Preferences.didChange, object: nil
        )
        observeBookmarks()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Every window's strip has to say the same thing about a file the
    /// moment any of them bookmarks it, so the list itself is what is
    /// listened to rather than the window that changed it. The registry
    /// swaps this window's list for the app's after `init`, which is why the
    /// old one is dropped first.
    private func observeBookmarks() {
        NotificationCenter.default.removeObserver(self, name: Bookmarks.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(bookmarksChanged),
            name: Bookmarks.didChange, object: bookmarks
        )
    }

    @objc private func bookmarksChanged() {
        refreshTabs()
        // With a registry there is one writer for the whole app and it is
        // listening too; on its own, this window is the session.
        if sessionWriter == nil { writeSessionFile() }
    }

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

        // Under the strip and over the split: the band the pointer has to
        // reach for an auto-hidden strip to come back. Added before the
        // strip so the strip that answers it lies over the top of it.
        tabBarHotZone.translatesAutoresizingMaskIntoConstraints = false
        tabBarHotZone.isHidden = true
        tabBarHotZone.onEnter = { [weak self] in self?.revealTabBarOverlay() }
        tabBarHotZone.onExit = { [weak self] in self?.scheduleTabBarOverlayHide() }
        workspace.addSubview(tabBarHotZone)

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.delegate = self
        tabBar.onPointerEntered = { [weak self] in self?.revealTabBarOverlay() }
        tabBar.onPointerExited = { [weak self] in self?.scheduleTabBarOverlayHide() }
        workspace.addSubview(tabBar)

        tabPicker.delegate = self

        configureTextView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        content.addSubview(scrollView)

        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        // The gutter numbers from the front note's line table rather than by
        // counting newlines itself, so scrolling a big file costs the rows on
        // screen and nothing else.
        ruler.lineIndexProvider = { [weak self] in self?.currentNote?.lineIndex }
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

        for label in [formatKindLabel, formatEncodingLabel, formatLineEndingLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
        }
        // The footer's regions are what a narrow window is measured against:
        // four badges at their full width would put a floor under the window
        // itself, and the window's floor is the columns' business, not the
        // status bar's. So this one — the newest of the four, and the one
        // whose word can be guessed from the tab's own name — is the one that
        // gives way, clipped by a narrow window rather than widening it.
        formatKindLabel.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal
        )
        formatKindLabel.onClick = { [weak self] in self?.showFormatKindMenu() }
        formatEncodingLabel.onClick = { [weak self] in self?.showEncodingMenu() }
        formatLineEndingLabel.onClick = { [weak self] in self?.showLineEndingMenu() }
        footerTrailingStack.translatesAutoresizingMaskIntoConstraints = false
        footerTrailingStack.orientation = .horizontal
        footerTrailingStack.alignment = .centerY
        footerTrailingStack.spacing = 8
        footerTrailingStack.detachesHiddenViews = true
        workspace.addSubview(footerTrailingStack)

        zenDragRegion.translatesAutoresizingMaskIntoConstraints = false
        zenDragRegion.isHidden = true
        zenDragRegion.onDropFiles = { [weak self] urls in self?.openDroppedFiles(urls) }
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

            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),

            tabBarHotZone.topAnchor.constraint(equalTo: workspace.topAnchor),
            tabBarHotZone.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            tabBarHotZone.trailingAnchor.constraint(equalTo: workspace.trailingAnchor),
            tabBarHotZone.heightAnchor.constraint(equalToConstant: Layout.zenTopInset),

            workspaceSplit.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
            workspaceSplit.trailingAnchor.constraint(equalTo: workspace.trailingAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),

            zenDragRegion.topAnchor.constraint(equalTo: content.topAnchor),
            zenDragRegion.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            zenDragRegion.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            zenDragRegion.heightAnchor.constraint(equalToConstant: Layout.hiddenStripDragBand),

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

            footerTrailingStack.trailingAnchor.constraint(
                equalTo: workspace.trailingAnchor, constant: -Layout.statusInset
            ),
            footerTrailingStack.centerYAnchor.constraint(equalTo: modeBadge.centerYAnchor),

            statusLabel.centerYAnchor.constraint(equalTo: modeBadge.centerYAnchor),
            statusLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: footerTrailingStack.leadingAnchor, constant: -12
            ),
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

        tabBar.trailingAnchor.constraint(
            equalTo: workspace.trailingAnchor, constant: -8
        ).isActive = true

        tabBarLeading = tabBar.leadingAnchor.constraint(
            equalTo: workspace.leadingAnchor, constant: Layout.trafficLightInset
        )
        tabBarLeading?.isActive = true

        tabBarTop = tabBar.topAnchor.constraint(equalTo: workspace.topAnchor)
        tabBarTop?.isActive = true

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

        editorTopToContent = scrollView.topAnchor.constraint(equalTo: content.topAnchor)
        // The same edge as with the strip: the document takes the whole
        // window once the strip is gone, and the drag band lies over its
        // padding rather than pushing it down.
        editorTopToZenInset = scrollView.topAnchor.constraint(equalTo: content.topAnchor)
        scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor).isActive = true
        editorTopToContent?.isActive = true
        applyStatusBarLayout()
        applyWindowChrome()

        installModeOverlay(editorModeOverlay, over: content)
        installFindBar(over: content)
        installExternalChangePill(over: content)
        installFormatOfferPill(over: content)
        applyEditorInsets()
    }

    /// ⌘F's pill, laid over the editor column after the mode control so it is
    /// the topmost thing in that corner. Its drop is measured from the scroll
    /// view rather than the column, so zen's clearance under the traffic
    /// lights carries it down with the text.
    private func installFindBar(over container: NSView) {
        textView.findSession = findSession
        findSession.onVisibilityChange = { [weak self] shown in
            // A bar on its way out has no re-scan to wait for.
            self?.findRefreshWorkItem?.cancel()
            self?.findRefreshWorkItem = nil
            // The two pills share one corner.
            if shown { self?.goToLineSession.hide(restoring: false) }
            self?.updateModeControlOverlays()
        }
        // The replace row makes the pill taller; the control drops further.
        findBar.onHeightChange = { [weak self] in self?.updateModeControlOverlays() }
        // ⌘F draws with the mechanism vim's own search draws with, so when
        // the bar puts its bands down vim puts its back.
        findSession.onHighlightsCleared = { [weak self] in
            self?.vimEngine.refreshSearchHighlights()
        }
        findBar.floatStack(
            in: container, under: scrollView.topAnchor,
            gap: ModeControlOverlay.controlTopInset,
            trailingInset: ModeControlOverlay.controlInset
        )

        // ⌘J stands in the same corner, on its own.
        goToLineSession.lineIndexProvider = { [weak self] in self?.currentNote?.lineIndex }
        goToLineSession.onVisibilityChange = { [weak self] shown in
            if shown { self?.findSession.hide() }
            self?.updateModeControlOverlays()
        }
        // ⌘F asked for from inside ⌘J's field: this one goes, that one comes.
        goToLineSession.onFindRequested = { [weak self] action in
            self?.findSession.perform(action)
        }
        goToLinePill.float(
            in: container, under: scrollView.topAnchor,
            gap: ModeControlOverlay.controlTopInset,
            trailingInset: ModeControlOverlay.controlInset
        )
    }

    // MARK: - The find the window falls back on

    /// ⌘F when nothing in the column being read wants it.
    ///
    /// Find…, Find Next, Find Previous and Use Selection for Find are
    /// nil-targeted `performTextFinderAction:` items, so they walk the
    /// responder chain from whatever has the keyboard. In split that may be a
    /// preview column's own view — a tree's outline, a dump's grid — which
    /// answers for the selector because it has to answer for it in reading
    /// mode, and there the find is the *editor's*: the column is a way into
    /// the text beside it, not a second place to search.
    ///
    /// Those views hand the item on rather than swallow it, and this is where
    /// it lands: the window controller sits in the chain after the window, so
    /// one fallback here serves every column. Without it the item is enabled
    /// by nobody and ⌘F is greyed out the moment a reader clicks a row.
    override func performTextFinderAction(_ sender: Any?) {
        guard let item = sender as? NSValidatedUserInterfaceItem,
              let action = NSTextFinder.Action(rawValue: item.tag)
        else { return }
        findSession.perform(action)
    }

    /// And the same for whether the item is enabled at all. Everything but
    /// the Find menu's own items is left to whoever else answers for it.
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(performTextFinderAction(_:)) else { return true }
        guard let action = NSTextFinder.Action(rawValue: item.tag) else { return false }
        return TextFindSession.handles(action)
    }

    /// The reload offer, in the editor column's other corner. Its bottom is
    /// measured from the scroll view rather than the column, so it rides with
    /// the text the way the find bar does.
    private func installExternalChangePill(over container: NSView) {
        externalChangePill.onReload = { [weak self] in self?.reloadFrontNoteFromDisk() }
        externalChangePill.onKeepMine = { [weak self] in
            // The buffer stands. The tab keeps its ring — the file really has
            // moved — and the next ⌘S writes over it. The offer has been
            // answered, so it does not come round again until the file does.
            self?.currentNote?.externalChangeOffer = false
            self?.externalChangePill.setShown(false)
        }
        externalChangePill.floatBottom(
            in: container, above: scrollView.bottomAnchor,
            gap: ModeControlOverlay.controlInset,
            trailingInset: ModeControlOverlay.controlInset
        )
    }

    /// The format offer, in the same corner as the reload offer — the two are
    /// both Nota speaking up rather than a tool the reader opened, and only
    /// one of them ever speaks at a time: the file having changed under the
    /// tab is the louder news, so the offer stands down while it is up.
    private func installFormatOfferPill(over container: NSView) {
        formatOfferPill.onAccept = { [weak self] in
            guard let self, let kind = formatOfferPill.offeredKind else { return }
            setFormat(.preview(kind))
            focusEditor()
        }
        formatOfferPill.onDismiss = { [weak self] in
            guard let self else { return }
            // Remembered against the reading it declined: the same guess is
            // never put twice, and only text that reads as something else
            // brings the pill back.
            currentNote?.declinedFormatKind = formatOfferPill.offeredKind
            cancelFormatOffer()
            focusEditor()
        }
        formatOfferPill.floatBottom(
            in: container, above: scrollView.bottomAnchor,
            gap: ModeControlOverlay.controlInset,
            trailingInset: ModeControlOverlay.controlInset
        )
    }

    // MARK: - The format offer

    /// How long after the last keystroke the text is looked at. Typing is not
    /// a moment to be interrupted, and a paste — which is the case this is
    /// really for — does not wait at all.
    var formatOfferDelay: TimeInterval = 1.5

    /// The offer, for the tests to read and press.
    var formatOffer: FormatOfferPill { formatOfferPill }

    /// What puts the paste's question to the reader. `nil` — which is every
    /// running window — builds the real sheet; the tests set it and answer
    /// by hand, since a sheet in a test is a run that never comes back.
    var formatAlertPresenter: ((RenderedPreviewKind, @escaping (Bool) -> Void) -> Void)?

    /// Whether a question is standing on this window. One at a time: while
    /// it is up neither a second paste nor a pause in the typing asks again.
    private var formatAlertIsUp = false

    /// Takes the offer down and forgets any look that was on its way. Called
    /// wherever the answer would be stale: a tab switch, a format picked in
    /// the footer, a file changed on disk.
    func cancelFormatOffer() {
        formatOfferWorkItem?.cancel()
        formatOfferWorkItem = nil
        formatOfferPill.setShown(false)
    }

    /// A keystroke. The look costs a walk over the text, so it waits for the
    /// pause after the typing the way the cache write and the render do.
    private func scheduleFormatOffer() {
        formatOfferWorkItem?.cancel()
        formatOfferWorkItem = nil
        guard tabCanBeOfferedAFormat else { return }
        let item = DispatchWorkItem { [weak self] in self?.runFormatDetection() }
        formatOfferWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + formatOfferDelay, execute: item)
    }

    /// The look itself, without the wait — the pill's half of the offer, and
    /// what the tests drive it through.
    func runFormatDetection() {
        formatOfferWorkItem?.cancel()
        formatOfferWorkItem = nil
        // A question is already standing on this tab; the sheet will answer
        // for it, and a pill under a sheet would be asking twice.
        guard !formatAlertIsUp, let kind = detectedFormatToOffer() else {
            return formatOfferPill.setShown(false)
        }
        formatOfferPill.offer(kind)
        formatOfferPill.setShown(true)
    }

    /// A note that arrived whole — pasted, or let go in the text. Nothing
    /// waits, and nothing is interrupted either: the typing this would have
    /// stopped is not happening, so this half of the offer is a real sheet
    /// with a default button rather than a pill in the corner.
    func offerFormatAfterBulkInsert() {
        // One question at a time. A second paste while the sheet is up is
        // the same tab asking again, and the sheet already answers for it.
        guard !formatAlertIsUp, let kind = detectedFormatToOffer() else { return }
        // The corner is not asked twice either: a pill that was up for this
        // tab goes as the sheet comes down over it.
        cancelFormatOffer()
        presentFormatOffer(kind)
    }

    /// What the text reads as, or `nil` for every reason there is not to ask
    /// — the tab is not one that gets offered anything, the note is too big
    /// to walk, it is too short to be anything, or its reading is the one
    /// this tab has already turned down.
    private func detectedFormatToOffer() -> RenderedPreviewKind? {
        guard tabCanBeOfferedAFormat, let note = currentNote else { return nil }
        // A big note is not read at all: the detector parses the whole text,
        // and a megabyte of it on every pause in the typing is the kind of
        // work the rest of the editor already declines past this line.
        guard !BigFile.isBig(length: note.storage.length) else { return nil }
        let text = note.storage.string
        // Cheap first: most notes are too short to be anything, and that is
        // answered without looking at a single character of them.
        guard text.count >= FormatDetector.minimumCharacters
                || text.split(whereSeparator: \.isNewline).count >= FormatDetector.minimumLines
        else { return nil }
        guard let kind = FormatDetector.detect(text), kind != note.declinedFormatKind else {
            return nil
        }
        return kind
    }

    /// Puts the question up and holds the tab it was asked about, so the
    /// answer lands where it was asked even though a window-modal sheet
    /// means nothing else can have moved meanwhile.
    private func presentFormatOffer(_ kind: RenderedPreviewKind) {
        guard let note = currentNote, let window else { return }
        formatAlertIsUp = true
        let answer: (Bool) -> Void = { [weak self, weak note] accepted in
            guard let self else { return }
            formatAlertIsUp = false
            if accepted {
                guard currentNote === note else { return }
                setFormat(.preview(kind))
            } else {
                // Remembered against the reading it declined, exactly as the
                // pill's "Not now" is: neither half of the offer puts the
                // same guess to this tab twice.
                note?.declinedFormatKind = kind
            }
            focusEditor()
        }
        if let formatAlertPresenter {
            formatAlertPresenter(kind, answer)
            return
        }
        FormatOfferAlert.make(for: kind).beginSheetModal(for: window) { response in
            answer(response == .alertFirstButtonReturn)
        }
    }

    /// Whether there is anything to offer this tab at all: an untitled text
    /// note, with no preview of its own and no word from the reader about
    /// what it is.
    ///
    /// A file is never offered anything, not even a `.txt`. A file has a
    /// name, and a name is its author saying what it is — a `.txt` full of
    /// JSON is somebody's `.txt`, and Nota has no business second-guessing it
    /// every time they type. The badge in the footer is still there for them,
    /// and one click does it. What the offer is for is the case with nobody's
    /// word on it at all: a fresh tab with something pasted into it.
    ///
    /// Nor while the file itself is speaking — the reload offer has that
    /// corner, and a tab that has no file cannot be in that case anyway.
    private var tabCanBeOfferedAFormat: Bool {
        guard let note = currentNote, note.kind == .text, note.fileURL == nil else { return false }
        guard note.formatOverride == nil, note.previewKind == nil else { return false }
        return !externalChangePill.isShown
    }

    /// ⌘J. Only where there is an editor on screen to jump about in, and only
    /// in a tab that is text — a PDF and a picture have no lines.
    var canGoToLine: Bool {
        installedPreviewMode != .reading && currentNote?.kind == .text
    }

    func showGoToLine() {
        guard canGoToLine else { return }
        goToLineSession.show()
    }


    /// The hover band across the top of a column, laid over whatever the
    /// column is showing. It is added last so it is the topmost thing there,
    /// and it hands every click but the control's own back to what is under
    /// it.
    private func installModeOverlay(_ overlay: ModeControlOverlay, over container: NSView) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        // The action on the end of the capsule, where the front tab's format
        // has one. Both columns carry it, so both are wired.
        overlay.onFormat = { [weak self] kind, action in self?.applyFormat(action, of: kind) }
        container.addSubview(overlay)
        // The band's height is the overlay's own: it grows while that
        // column's find bar is up, so the whole top of the column is still
        // the hover target with the control sitting lower in it.
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    /// A segment clicked in either column's control — one of the three modes,
    /// or the format action standing ahead of them.
    @objc private func previewModeControlChanged(_ sender: NSSegmentedControl) {
        let clicked = [editorModeOverlay, previewModeOverlay]
            .first { $0.modeControl === sender }
        // The action is a button living in a `.selectOne` control: it fires,
        // and the selection goes straight back to the mode the tab is in.
        // `handleFormatSegmentClick` already knows which segment is its own
        // and whether this tab even has one, so there is nothing left here
        // to ask about the click before handing it over.
        if let clicked, clicked.handleFormatSegmentClick(restoringMode: previewMode) {
            return
        }
        guard let mode = clicked?.mode(ofSegment: sender.selectedSegment) else { return }
        setPreviewMode(mode)
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
        container.addSubview(imageSidebar)
        // The contents list sits in the same rectangle, behind it: the column
        // is one split item whichever of the two it is showing, so its width,
        // its side and everything that collapses it are the same either way.
        contentsSidebar.translatesAutoresizingMaskIntoConstraints = false
        contentsSidebar.delegate = self
        contentsSidebar.isHidden = true
        container.addSubview(contentsSidebar)
        pageListSidebar.translatesAutoresizingMaskIntoConstraints = false
        pageListSidebar.delegate = self
        pageListSidebar.isHidden = true
        container.addSubview(pageListSidebar)
        NSLayoutConstraint.activate([
            imageSidebar.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            imageSidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageSidebar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageSidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            contentsSidebar.topAnchor.constraint(
                equalTo: container.safeAreaLayoutGuide.topAnchor
            ),
            contentsSidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentsSidebar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentsSidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            pageListSidebar.topAnchor.constraint(
                equalTo: container.safeAreaLayoutGuide.topAnchor
            ),
            pageListSidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pageListSidebar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pageListSidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
        previewColumn.onTaskToggle = { [weak self] source in
            self?.toggleTask(inSource: source)
        }
        previewColumn.onSourceReveal = { [weak self] sources in
            self?.revealSource(sources)
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
        previewColumn.onZoomChange = { [weak self] zoom in
            self?.previewZoomDidChange(zoom)
        }
        // The pill in the column's other corner presses the same three keys
        // the reader would: one path through the window for a zoom, whichever
        // hand asked for it.
        previewColumn.onZoomCommand = { [weak self] command in
            switch command {
            case .zoomOut: self?.zoomOut()
            case .actualSize: self?.actualSize()
            case .zoomIn: self?.zoomIn()
            }
        }
        // The content wrote something on the note itself — the table a dump
        // is open at, the query beside it. Nothing to apply here; the note
        // already holds it, and all that is left is the session.
        previewColumn.onStateChange = { [weak self] in
            self?.scheduleSave()
        }
        previewColumn.onDropFiles = { [weak self] urls in
            self?.openDroppedFiles(urls)
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
        // Written down here, where the side is actually installed, and not
        // read lazily later: the first read used to happen inside
        // `preferencesChanged`, after the side had already been switched, so
        // it initialised to the new side, saw nothing to do, and the column
        // moved only on the next launch.
        installedSidebarSide = side
        updateTabStripInset()
    }

    /// The strip clears the traffic lights only when they sit over the editor
    /// pane — with a left sidebar showing, they are over the sidebar instead.
    /// The lights being gone from the corner for any reason — hidden
    /// outright, or merely idling off-screen under auto-hide — frees their
    /// slot the same way: the strip takes it, starting at the same 12pt
    /// inset.
    private func updateTabStripInset() {
        let leftSidebarShowing =
            preferences.sidebarSide == .left && !(sidebarItem?.isCollapsed ?? true)
        let lightsGoneFromTheCorner = leftSidebarShowing || !trafficLightsAreVisible
        tabBarLeading?.constant = lightsGoneFromTheCorner ? 12 : Layout.trafficLightInset
    }

    private func configureTextView() {
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        // Nota brings its own find bar, so AppKit's never installs itself
        // above the text: ⌘F opens the pill in the corner instead.
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        // The real answer is per tab — a `.log` gets no dictionary, a big note
        // gets no dictionary regardless of its extension — and is set again in
        // `installCurrentNote` once there is a note to ask. This default is
        // only what a brand-new, empty text view starts out with.
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
        // A note that arrived whole — pasted, or let go in the text — is not
        // typing that might carry on, so its reading is put to the reader on
        // the spot, and as a sheet rather than the corner's pill.
        textView.onBulkInsert = { [weak self] in self?.offerFormatAfterBulkInsert() }
        // The line keys read the front note's own line table, comment by the
        // front note's extension, and stand aside wherever vim has the keys.
        textView.lineIndexProvider = { [weak self] in self?.currentNote?.lineIndex }
        textView.fileExtensionProvider = { [weak self] in
            self?.currentNote?.fileURL?.pathExtension
        }
        textView.lineOperationsAllowed = { [weak self] in
            guard let self else { return false }
            return !vimEngine.isEnabled || vimEngine.mode == .insert
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
        textView.highlightsCurrentLine = preferences.highlightsCurrentLine
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

        // A slide is holding the container at the width it is leaving —
        // see `freezeEditorWrapWidth()`. Anything that calls in here while
        // that is true (a settings change mid-slide, say) leaves the width
        // alone; `thawEditorWrapWidth()` calls back in once there is a final
        // width to wrap to.
        guard !editorWrapWidthIsFrozen else { return }

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
        // `sizeToFit` asks the layout manager for the container's used rect,
        // which — with `allowsNonContiguousLayout` — is happy to answer with
        // an estimate for whatever is not laid out yet. Forcing full layout
        // first, the way this used to, defeated that: a container switch or a
        // word-wrap toggle on a big note would lay out the whole thing right
        // here. Laying out only what is on screen is enough to make the used
        // rect (and so the frame `sizeToFit` computes) correct for the part
        // that matters; the rest firms up as the reader scrolls into it.
        textView.layoutManager?.ensureLayout(forBoundingRect: scrollView.contentView.bounds, in: container)
        textView.sizeToFit()
        lineNumberRuler?.refresh()
    }

    /// The editor's side of the trick `RenderedPreviewView.freezeWidth()`
    /// plays on the render: hold the text container at the width it is
    /// leaving so a preview-mode slide does not re-wrap the whole note on
    /// every frame the divider crosses. With word wrap on, the container is
    /// welded to the text view's width (`widthTracksTextView`), so as the
    /// split resizes the editor every frame, AppKit re-wraps every frame
    /// along with it — turning that tracking off for the length of the slide
    /// is what removes the lag.
    ///
    /// Word wrap off leaves the container unbounded already, so there is
    /// nothing to freeze. And an editor coming in from a collapsed column
    /// has no width worth holding either — its first real width is the one
    /// it lands at — the same rule `freezeWidth()` applies to the render.
    private func freezeEditorWrapWidth() {
        guard preferences.wrapsLines, !editorWrapWidthIsFrozen,
              let container = textView.textContainer, container.size.width > 1
        else { return }
        editorWrapWidthIsFrozen = true
        container.widthTracksTextView = false
    }

    /// Lets the editor take the column's width again and wrap to it once, at
    /// the width the slide landed on. A no-op when nothing was frozen — the
    /// non-animated paths call this too, the way `thawWidth()` is safe to
    /// call whether or not `freezeWidth()` ever took.
    private func thawEditorWrapWidth() {
        guard editorWrapWidthIsFrozen else { return }
        editorWrapWidthIsFrozen = false
        applyWordWrap()
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
        applyStatusBarLayout()
        applyWindowChrome()
        updateStatus()
        scheduleSave()
    }

    /// Settings › Tab bar: the tab strip, the traffic lights and the strip's
    /// three trailing buttons can each be switched off. The strip and the
    /// lights share their mechanism with zen mode, which takes both for as
    /// long as it is on; the buttons are the layout's business.
    private func applyWindowChrome() {
        let controls = TabStripLayout.TrailingControls(
            bookmarkToggle: !preferences.hidesBookmarkToggleButton,
            bookmark: !preferences.hidesBookmarkButton,
            settings: !preferences.hidesSettingsButton
        )
        if TabStripLayout.controls != controls {
            TabStripLayout.controls = controls
            tabBar.needsLayout = true
        }
        applyTopChrome()
    }

    /// Whether the tab strip is off the window right now — zen, or either
    /// of the two settings that take it. Auto-hide takes it out of the
    /// layout exactly as the plain hide does; what makes it different is
    /// that it can come back over the top without going back in.
    private var hidesTabBar: Bool {
        isZenMode || preferences.hidesTabBar || preferences.autoHidesTabBar
    }

    /// Whether the strip is merely parked off the top waiting for the
    /// pointer. Zen mode and "Hide tab bar" both win: under either of them
    /// the strip is gone for good and the top edge watches for nothing.
    private var autoHidesTabBar: Bool {
        !isZenMode && !preferences.hidesTabBar && preferences.autoHidesTabBar
    }

    /// Whether the traffic lights are on screen right now. Off in zen, under
    /// "Hide traffic lights", and under "Hide tab bar" — which takes the
    /// lights the same way zen does, since there is no strip left for them
    /// to clear. Auto-hide idles the same way while the strip is off-screen,
    /// and brings the lights back with it the moment the pointer reveals
    /// it — unless "Hide traffic lights" is what is keeping them off.
    /// `applyTopChrome` and the overlay reveal/hide paths all read this one
    /// property, so the buttons and the strip's inset never disagree.
    private var trafficLightsAreVisible: Bool {
        !(isZenMode || preferences.hidesTrafficLights || preferences.hidesTabBar
            || (autoHidesTabBar && !isTabBarOverlayVisible))
    }

    /// Shows or hides the three window buttons to match
    /// `trafficLightsAreVisible`.
    private func applyTrafficLightsVisibility() {
        let hidden = !trafficLightsAreVisible
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(button)?.isHidden = hidden
        }
    }

    /// The strip and the traffic lights, on or off, from whichever of zen and
    /// Settings wants them gone. The constraints are zen's own: the workspace
    /// meets the top of the pane and the editor keeps a slim inset the
    /// window can be dragged by.
    private func applyTopChrome() {
        let hidesTop = hidesTabBar
        workspaceSplitTopToTabBar?.isActive = !hidesTop
        workspaceSplitTopToPane?.isActive = hidesTop
        editorTopToContent?.isActive = !hidesTop
        editorTopToZenInset?.isActive = hidesTop
        previewColumn.isZenMode = hidesTop
        zenDragRegion.isHidden = !hidesTop

        // Auto-hide leaves the layout alone and hands the strip to the
        // pointer: the top edge watches, and the strip that answers lies
        // over the split rather than pushing it down.
        let overlays = autoHidesTabBar
        tabBarHotZone.isHidden = !overlays
        if !overlays { endTabBarOverlay() }
        tabBar.drawsOpaqueBackground = overlays

        // Outside a zen fade the strip simply is or is not there — unless it
        // is the auto-hidden one, currently answering the pointer.
        if !isZenMode { tabBar.isHidden = hidesTop && !isTabBarOverlayVisible }
        applyTrafficLightsVisibility()
        // Hiding or showing the lights hands their slot to the strip (or
        // takes it back), live, whenever this runs from a Settings change.
        updateTabStripInset()
    }

    // MARK: - Auto-hidden tab strip

    /// The pointer has reached the top edge (or is on the strip already):
    /// the strip slides down over the split and stays until it leaves.
    /// Anything but an auto-hidden strip ignores this entirely.
    private func revealTabBarOverlay() {
        guard autoHidesTabBar else { return }
        cancelTabBarOverlayHide()
        guard !isTabBarOverlayVisible else { return }
        isTabBarOverlayVisible = true
        tabBar.drawsOpaqueBackground = true
        tabBar.isHidden = false
        tabBar.alphaValue = 0
        tabBarTop?.constant = -TabBarView.height
        // The lights come back with the strip — unless "Hide traffic
        // lights" keeps them off — and the strip's inset follows suit, so
        // it starts at 82 or 12 depending on which is true before the
        // slide-in frame is captured.
        applyTrafficLightsVisibility()
        updateTabStripInset()
        tabBar.superview?.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.tabBarOverlaySlide
            tabBarTop?.animator().constant = 0
            tabBar.animator().alphaValue = 1
        }
        // And the deadline that lands it: the strip is one slide away
        // whether or not there was a frame to spare for the animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + Layout.tabBarOverlaySlide) {
            [weak self] in
            guard let self, self.isTabBarOverlayVisible else { return }
            self.tabBarTop?.constant = 0
            self.tabBar.alphaValue = 1
        }
    }

    /// The pointer has left the strip or the band under it. Nothing happens
    /// for a grace period — crossing the gap between the two, or reaching
    /// past the strip for a menu, must not chase it away.
    private func scheduleTabBarOverlayHide() {
        guard isTabBarOverlayVisible else { return }
        cancelTabBarOverlayHide()
        let timer = Timer(timeInterval: Layout.tabBarOverlayGrace, repeats: false) {
            [weak self] timer in
            guard let self, self.tabBarOverlayHideTimer === timer else { return }
            self.tabBarOverlayHideTimer = nil
            self.hideTabBarOverlayIfPointerHasGone()
        }
        RunLoop.main.add(timer, forMode: .common)
        tabBarOverlayHideTimer = timer
    }

    private func cancelTabBarOverlayHide() {
        tabBarOverlayHideTimer?.invalidate()
        tabBarOverlayHideTimer = nil
    }

    /// The grace period is up. A drag, an open context menu, or a pointer
    /// still over the strip each buy another one — a gesture the pointer
    /// owns is never interrupted by the strip going away under it.
    private func hideTabBarOverlayIfPointerHasGone() {
        guard isTabBarOverlayVisible else { return }
        guard !tabBar.isDraggingForOverlay,
              !tabBar.isShowingContextMenuForOverlay,
              !pointerIsOverTabBarOverlay()
        else { return scheduleTabBarOverlayHide() }
        hideTabBarOverlay()
    }

    /// Where the pointer is now, rather than where the last enter/exit left
    /// it: the strip appearing under a pointer that is already there sends
    /// no enter of its own, so the frames are what settle it.
    private func pointerIsOverTabBarOverlay() -> Bool {
        guard let window, let workspace = tabBar.superview, window.isKeyWindow else { return false }
        let point = workspace.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return tabBar.frame.contains(point) || tabBarHotZone.frame.contains(point)
    }

    private func hideTabBarOverlay() {
        cancelTabBarOverlayHide()
        guard isTabBarOverlayVisible else { return }
        isTabBarOverlayVisible = false
        // Idling again, the lights go with the strip — unless they were
        // already off for some other reason — and the strip's inset
        // reverts with them.
        applyTrafficLightsVisibility()
        updateTabStripInset()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.tabBarOverlaySlide
            tabBarTop?.animator().constant = -TabBarView.height
            tabBar.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Layout.tabBarOverlaySlide) {
            [weak self] in
            guard let self, !self.isTabBarOverlayVisible else { return }
            self.tabBar.isHidden = true
            self.tabBarTop?.constant = 0
            self.tabBar.alphaValue = 1
        }
    }

    /// Auto-hide has stopped applying — the setting went, or zen or "Hide
    /// tab bar" took the strip outright. Every trace of the overlay goes
    /// with it and `applyTopChrome` decides the strip's fate as it always
    /// did.
    private func endTabBarOverlay() {
        cancelTabBarOverlayHide()
        isTabBarOverlayVisible = false
        tabBarTop?.constant = 0
        tabBar.alphaValue = 1
        tabBar.drawsOpaqueBackground = false
    }

    /// Test hooks: what the two tracking areas do, without a pointer.
    internal func pointerEnteredHotZoneForTesting() { revealTabBarOverlay() }
    internal func pointerLeftTabBarForTesting() { scheduleTabBarOverlayHide() }
    internal var isTabBarOverlayVisibleForTesting: Bool { isTabBarOverlayVisible }
    /// The split the overlaid strip lies over, for the frame check.
    internal var workspaceSplitForTesting: NSView { workspaceSplitViewController.view }
    /// The band a hidden strip leaves across the top of the editor column —
    /// the other tab target files can be let go on.
    internal var topDragBandForTesting: DragRegionView { zenDragRegion }

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
        LaunchTiming.mark("tab files read (\(notes.count) tabs)")

        if pruningCache { store.pruneCache(keeping: notes.map(\.id)) }
        finishRestore()
    }

    /// A window opened around notes that already exist — one torn off
    /// another window. Nothing is read and nothing is pruned: the notes
    /// bring their text, their undo history and their cache files with them.
    private func adopt(_ adopted: [Note]) {
        notes = adopted
        for note in notes { watchFile(of: note) }
        selectedIndex = 0
        finishRestore()
    }

    private func finishRestore() {
        installCurrentNote()
        LaunchTiming.mark("restore: installCurrentNote")
        refreshTabs()
        LaunchTiming.mark("restore: refreshTabs")
        updateStatus()
        LaunchTiming.mark("restore: updateStatus")
        refreshImages(force: true)
        LaunchTiming.mark("restore: refreshImages")
        flush()
        LaunchTiming.mark("restore: flush")
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
            format: format,
            // A clean tab has just re-read its file, so its own relative
            // image links come back as chips exactly as an open reads them.
            // A dirty one came out of the cache, which holds tokens already.
            importing: (fileURL.flatMap { isDirty ? nil : $0 })
                .map { Sidecar.importer(forFileAt: $0, assets: store.assets) }
        )
        note.isDirty = isDirty
        watchFile(of: note)
        note.selectionLocation = max(0, min(tab.selection, note.storage.length))
        // A session written before the mode was per-tab says nothing, and
        // those tabs come back in the editor.
        note.previewMode = tab.previewMode ?? .off
        // Where a dump was left in its own database. Nothing checks them
        // here: the pane asks the file whether the table is still there.
        note.sqlTable = tab.sqlTable
        note.sqlQuery = tab.sqlQuery
        // What the reader told the footer this tab is. A spelling this
        // version does not know is simply not an override, and the tab comes
        // back going by its name.
        note.formatOverride = tab.formatOverride.flatMap(NoteFormat.init(canonicalExtension:))
        // And whether it came back owing a name. Only where the override
        // itself came back: a spelling this version does not know is not an
        // override, and a tab going by its name owes nothing.
        note.needsSaveAs = tab.needsSaveAs == true && note.formatOverride != nil
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
        case .epub: NoteKind.epub
        case .rtf: NoteKind.rtf
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
        // Only a book writes one, and only a book reads it back: the chapter
        // alone would come back to the top of a chapter half read.
        note.scrollFraction = min(1, max(0, tab.scroll ?? 0))
        watchFile(of: note)
        return note
    }

    private func normalizeUntitledNames() {
        for note in notes where note.fileURL == nil && note.untitledName == nil {
            note.untitledName = UntitledNaming.nextName(existing: notes.map(\.title))
        }
    }

    private func makeUntitledNote() -> Note {
        let note = Note(
            id: UUID(),
            fileURL: nil,
            untitledName: UntitledNaming.nextName(existing: notes.map(\.title)),
            text: "",
            attributes: defaultAttributes,
            assets: store.assets
        )
        // Nothing to watch yet — but ⌘S will give it a file, and the watch
        // starts itself then.
        watchFile(of: note)
        return note
    }

    // MARK: - Tabs

    private var currentNote: Note? {
        notes.indices.contains(selectedIndex) ? notes[selectedIndex] : nil
    }

    private func installCurrentNote() {
        guard let note = currentNote, let layoutManager = textView.layoutManager else { return }
        // The bar was searching the tab you are leaving, and its bands are
        // laid on the storage about to be swapped out from under them. ⌘J's
        // line number belonged to that note's table just as much.
        findSession.close()
        goToLineSession.hide(restoring: false)
        // The offer belongs to the tab being left, not to the corner. Both
        // offers: the file's news, and Nota's reading of the text.
        externalChangePill.setShown(false, animated: false)
        formatOfferWorkItem?.cancel()
        formatOfferWorkItem = nil
        formatOfferPill.setShown(false, animated: false)
        textView.breakUndoCoalescing()
        // Whatever is selected belongs to the tab being left — a ⌘F match,
        // say — and it is a range into storage that is about to be swapped
        // out from under it. AppKit does not always clamp it, and the
        // attributes laid on below would then be laid on a range that is not
        // there. Putting it down is part of the swap rather than the reader
        // moving the caret, so the bookkeeping a real selection change drives
        // is held off over it — a PDF's page, in particular, is not a caret
        // position and must not be written from one.
        isSwappingNote = true
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        isSwappingNote = false
        layoutManager.replaceTextStorage(note.storage)
        installedStorage = note.storage
        // A scratch tab is vim's `'nomodifiable'`: the motions still work, the
        // keyboard does not. A PDF has no text behind it to type into either.
        textView.isEditable = note.isEditable
        vimEngine.isModifiable = note.isEditable
        // A PDF or a picture has no dictionary to run either way; the policy
        // itself already says no for anything that is not prose (by
        // extension) and for anything past `BigFile.threshold`.
        textView.isContinuousSpellCheckingEnabled =
            SpellCheckPolicy.shouldCheck(url: note.fileURL, length: note.storage.length)
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
        // A tab coming to the front is a tab getting focus: if it was marked
        // while it was behind, this is when it says so.
        showExternalChangeOfferIfOwed()
        // And the reading of the tab you have landed on, asked afresh — the
        // offer is per tab, so the one that was up belonged to the tab you
        // left and this one gets its own answer.
        runFormatDetection()
    }

    /// Also re-asks whether the tab in front is Markdown: ⌘S is where an
    /// untitled note gets a name, and a `.txt` has no mode control.
    private func refreshTabs() {
        tabBar.setItems(
            notes.map {
                TabBarItem(title: $0.title, isDirty: $0.isDirty,
                           hasExternalChange: $0.isDirty && $0.hasExternalChange,
                           symbolName: $0.iconSymbolName,
                           isBookmarked: $0.fileURL.map(bookmarks.contains) ?? false,
                           hasFile: $0.fileURL != nil)
            },
            selectedIndex: selectedIndex
        )
        // The strip's own Bookmark button is about the tab in front, not
        // about any one row, so it is told separately — and told here, which
        // is the one place a tab switch, a save, a rename and another
        // window's bookmark all come through.
        // Any tab, an untitled note included: the button is ⌘D by another
        // door, and ⌘D on a note with no file asks for a name first.
        tabBar.setFrontTabBookmark(
            canBookmark: canBookmarkCurrentTab, isBookmarked: currentTabIsBookmarked
        )
        updateModeControlOverlays()
    }

    /// `countsDebounced` is the difference between a keystroke and everything
    /// else: only typing can afford to let a big file's word count arrive late.
    private func updateStatus(countsDebounced: Bool = false) {
        // A PDF has no words, characters, pictures or lines to speak of, and
        // neither has a picture. How long a document is, is how many pages;
        // how big a picture is, is how many pixels. The content in the column
        // is what says so, already written out; a render has nothing of its
        // own to add, and the counts stand.
        if let status = currentPreviewFooterStatus {
            previewStatus = status
        } else if let note = currentNote {
            previewStatus = nil
            // Lines and pictures are always cheap now: one is the size of the
            // note's line table, the other a walk over its attribute runs.
            counts.lines = note.lineIndex.lineCount
            counts.images = note.imageCount
            if BigFile.isBig(length: note.storage.length) {
                // Words and characters are the two that cost the whole file,
                // so a big one counts them off the main thread and the footer
                // keeps the last answer until the new one lands.
                scheduleWordCounts(for: note, debounced: countsDebounced)
            } else {
                // An ordinary note counts where it always did, on the spot:
                // the footer is right the instant a key is pressed, and at
                // this size that costs nothing worth deferring.
                let stripped = note.countableText
                counts.words = TextStats.wordCount(stripped)
                counts.characters = TextStats.characterCount(stripped)
                // The tasks are counted in the same place and the same pass
                // the words are: at this size a scan of the note costs
                // nothing worth deferring.
                taskCounts = note.countsTasks ? TaskList.counts(in: stripped) : nil
            }
        } else {
            previewStatus = nil
            counts = (words: 0, characters: 0, images: 0, lines: 1)
            taskCounts = nil
        }
        updateCountsLabel()
        updateCursorPosition()
        updateFormatLabel()
        applyFooterVisibility()
    }

    /// The note's own shape, at the right of the counts: `UTF-8` and `LF`,
    /// read straight off `note.format` since it is already what ⌘S would
    /// write. Empty for a PDF or a picture, which has no such thing.
    private func updateFormatLabel() {
        guard let note = currentNote, note.kind == .text else {
            formatKindLabel.stringValue = ""
            formatEncodingLabel.stringValue = ""
            formatLineEndingLabel.stringValue = ""
            return
        }
        formatKindLabel.stringValue = L10n.text(note.effectiveFormat.displayName)
        formatEncodingLabel.stringValue = TextFileFormat.displayName(for: note.format.encoding)
        formatLineEndingLabel.stringValue = note.format.lineEnding.displayName
    }

    // MARK: - The format badge

    private func showFormatKindMenu() {
        guard let menu = formatKindMenu() else { return }
        popUpFooterMenu(menu, over: formatKindLabel)
    }

    /// What clicking the format half offers: every format Nota can put in the
    /// preview column, in `NoteFormat.all`'s order, the tab's own ticked.
    /// `nil` off a PDF, a picture, or no note at all — a viewer is not read
    /// as anything, it *is* something. Exposed (not private) so tests can
    /// inspect it without going through a real click.
    func formatKindMenu() -> NSMenu? {
        guard let note = currentNote, note.kind == .text else { return nil }
        let menu = NSMenu()
        let current = note.effectiveFormat
        for format in NoteFormat.all {
            let item = NSMenuItem(
                title: L10n.text(format.displayName),
                action: #selector(chooseFormatKind(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = format.canonicalExtension
            item.state = format == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func chooseFormatKind(_ sender: NSMenuItem) {
        guard let spelling = sender.representedObject as? String,
              let format = NoteFormat(canonicalExtension: spelling)
        else { return }
        setFormat(format)
    }

    /// The one way the format a tab is read as ever changes: the badge's
    /// menu, and the offer pill, both come through here.
    ///
    /// Picking what the file name already says puts the override *down*
    /// rather than writing it: the name is saying it, so there is nothing for
    /// the tab to remember, and a later Save As is free to change what the
    /// tab is again.
    func setFormat(_ format: NoteFormat) {
        guard let note = currentNote, note.kind == .text else { return }
        let previousOverride = note.formatOverride
        note.formatOverride = format == NoteFormat.ofFile(note.fileURL) ? nil : format
        // A file the reader has said is something its name does not say is a
        // file that wants a new name. The tab goes dirty the way an edit
        // makes it dirty — the strip's dot, the close confirmation and the
        // session record all follow from the one flag — and the next ⌘S
        // opens the panel with this format already picked in the combo.
        //
        // Picking the name's own format again puts that need down. It does
        // not put the dirty mark down: dirty is one flag for the whole tab,
        // and there may be an edit under it that this had nothing to do with.
        if note.fileURL != nil, note.formatOverride != previousOverride {
            note.needsSaveAs = note.formatOverride != nil
            if note.needsSaveAs { note.isDirty = true }
        }
        // The reader has said what this is. Whatever the detector was about
        // to say, or has just said, is answered.
        note.declinedFormatKind = nil
        cancelFormatOffer()
        applyFormatChange(for: note)
    }

    /// Everything that follows from a tab being a different format than it
    /// was a moment ago — the same path a Save As under a new name takes,
    /// since that is the other way a tab changes what it renders as.
    private func applyFormatChange(for note: Note) {
        // A tab that no longer has a preview cannot be in one of the two
        // modes that show one.
        if !note.supportsRenderedPreview { note.previewMode = .off }
        refreshTabs()
        applyPreviewMode()
        updateModeControlOverlays()
        refreshPreviewContent()
        updatePreviewModeControl()
        updateStatus()
        flushAll()
    }

    // MARK: - Encoding and line endings

    private func showEncodingMenu() {
        guard let menu = encodingMenu() else { return }
        popUpFooterMenu(menu, over: formatEncodingLabel)
    }

    private func showLineEndingMenu() {
        guard let menu = lineEndingMenu() else { return }
        popUpFooterMenu(menu, over: formatLineEndingLabel)
    }

    private func popUpFooterMenu(_ menu: NSMenu, over view: NSView) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    /// What clicking the encoding half offers for the tab in front: UTF-8,
    /// UTF-16, Latin-1, Windows-1252 — Todo 2's own order — the current one
    /// ticked, and one this note's text cannot survive disabled rather than
    /// picked, with the tool tip saying why. `nil` off a PDF, a picture, or
    /// no note at all. Exposed (not private) so tests can inspect it without
    /// going through a real click.
    func encodingMenu() -> NSMenu? {
        guard let note = currentNote, note.kind == .text else { return nil }
        let menu = NSMenu()
        let text = note.text
        let currentName = TextFileFormat.displayName(for: note.format.encoding)
        for encoding in TextFileFormat.selectableEncodings {
            let name = TextFileFormat.displayName(for: encoding)
            let item = NSMenuItem(
                title: name, action: #selector(chooseEncoding(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = encoding.rawValue
            item.state = name == currentName ? .on : .off
            if !TextFile.canRepresent(text, in: encoding) {
                item.isEnabled = false
                item.toolTip = "“\(note.title)” has characters \(name) can’t hold."
            }
            menu.addItem(item)
        }
        return menu
    }

    /// What clicking the line-ending half offers for the tab in front: LF
    /// and CRLF, the current one ticked. Always both enabled — nothing a
    /// line ending cannot hold. `nil` off a PDF, a picture, or no note.
    func lineEndingMenu() -> NSMenu? {
        guard let note = currentNote, note.kind == .text else { return nil }
        let menu = NSMenu()
        for ending in [LineEnding.lf, .crlf] {
            let item = NSMenuItem(
                title: ending.displayName, action: #selector(chooseLineEnding(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = ending.rawValue
            item.state = ending == note.format.lineEnding ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func chooseEncoding(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? UInt else { return }
        convertEncoding(to: String.Encoding(rawValue: raw))
    }

    @objc private func chooseLineEnding(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let ending = LineEnding(rawValue: raw)
        else { return }
        convertLineEnding(to: ending)
    }

    /// What picking another encoding from the footer's menu does, for the
    /// tab in front: the note's format changes, the tab goes dirty, and ⌘S
    /// writes the new shape — `write(note:to:)` already reads `note.format`.
    /// UTF-16 is one menu item for either byte order, so picking it while the
    /// file is already UTF-16 (of either kind) is a no-op rather than a
    /// silent LE/BE flip. A conversion the text cannot survive is refused —
    /// the menu already keeps it from being asked for, this is the belt to
    /// that braces.
    func convertEncoding(to encoding: String.Encoding) {
        guard let note = currentNote, note.kind == .text else { return }
        let name = TextFileFormat.displayName(for: encoding)
        guard name != TextFileFormat.displayName(for: note.format.encoding) else { return }
        guard TextFile.canRepresent(note.text, in: encoding) else { return }
        note.format.encoding = encoding
        // Consistent with what `TextFile.decode` would produce for this
        // shape: UTF-16 is only ever recognised by its byte-order mark, so a
        // converted file gets one; UTF-8 and the 8-bit encodings never do.
        note.format.hadBOM = encoding == .utf16LittleEndian || encoding == .utf16BigEndian
        markFormatChanged(note)
    }

    /// What picking another line ending does, for the tab in front — the
    /// same shape of change as the encoding above, with nothing to refuse:
    /// every line ending can hold every note.
    func convertLineEnding(to ending: LineEnding) {
        guard let note = currentNote, note.kind == .text, ending != note.format.lineEnding
        else { return }
        note.format.lineEnding = ending
        markFormatChanged(note)
    }

    private func markFormatChanged(_ note: Note) {
        note.isDirty = true
        refreshTabs()
        updateFormatLabel()
    }

    /// Count the words and characters of a big note away from the run loop.
    ///
    /// Typing debounces — a burst of keystrokes counts once, about half a
    /// second after it stops — while opening a file or switching to a tab
    /// counts straight away, since the footer would otherwise be showing the
    /// tab you just left. Each job takes a number; only the newest one, and
    /// only while its note is still the one in front, is allowed to write to
    /// the footer.
    private func scheduleWordCounts(for note: Note, debounced: Bool) {
        wordCountWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.startWordCounts(for: note) }
        wordCountWorkItem = item
        if debounced {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
        } else {
            item.perform()
        }
    }

    private func startWordCounts(for note: Note) {
        wordCountWorkItem = nil
        wordCountGeneration += 1
        let generation = wordCountGeneration
        // What crosses the thread has to be a string of its own. Bridging a
        // storage's `string` is that snapshot already — it copies on the way
        // out, which `testSerializedTextIsASnapshot` pins — so nothing here
        // copies it a second time. Better still is the text a file was just
        // read from: already a string, and already in hand.
        let snapshot: String
        if let opened = openedText, opened.id == note.id {
            snapshot = opened.text
            openedText = nil
        } else {
            snapshot = note.storage.string
        }

        // The tasks ride this pass rather than one of their own: a big note's
        // `3 / 7 done` is another whole-file scan, and the main thread is
        // exactly where it must not happen.
        let countsTasks = note.countsTasks

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let stripped = NoteText.strippingTokens(snapshot)
            let words = TextStats.wordCount(stripped)
            let characters = TextStats.characterCount(stripped)
            let tasks = countsTasks ? TaskList.counts(in: stripped) : nil
            DispatchQueue.main.async {
                guard let self, generation == self.wordCountGeneration,
                      self.currentNote === note
                else { return }
                self.counts.words = words
                self.counts.characters = characters
                self.taskCounts = tasks
                self.updateCountsLabel()
            }
        }
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
                segments: preferences.footerSegments,
                // A `.md` with task items in it says how many are done, after
                // the counts and in the footer's own punctuation. It is the
                // last thing given up when the middle runs short of room.
                tasks: previewStatus == nil ? taskCounts : nil
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

    /// The gap between the left region and whatever bounds the counts on the
    /// right — the format field when a text note has one to show, the caret
    /// position otherwise — with the 12pt breathing space at each end already
    /// taken off.
    private var availableCountsWidth: CGFloat {
        // Before the first layout pass there are no frames to measure, so
        // nothing is ruled out yet.
        guard let workspace = statusLabel.superview, workspace.bounds.width > 0,
              footerTrailingStack.isHidden || footerTrailingStack.frame.maxX > 0
        else { return .greatestFiniteMagnitude }
        // Mirrors the two leading constraints exactly: 12pt clear of the
        // pending keys with vim mode on, the status inset without it.
        let leading = preferences.vimMode
            ? pendingKeysLabel.frame.maxX + 12
            : Layout.statusInset
        // The stack is what stands in the workspace; the labels inside it lay
        // out in the stack's own space, so their frames say nothing about
        // where the counts have to stop. With every region off, the stack is
        // gone and the counts run to the inset.
        let trailingBound = footerTrailingStack.isHidden
            ? workspace.bounds.maxX - Layout.statusInset
            : footerTrailingStack.frame.minX
        return max(0, trailingBound - 12 - leading)
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
        let location = textView.selectedRange().location
        guard let note = currentNote else {
            cursorLabel.stringValue = TextStats.position(in: "" as NSString, at: location)
            return
        }
        // Through the line table, and through the storage's own live view of
        // its characters: the line is a binary search, the column is the
        // caret's own line, and nothing is copied to find either.
        cursorLabel.stringValue = TextStats.position(
            in: note.storage.mutableString, at: location, using: note.lineIndex
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

    /// The footer's regions, for the layout tests: the vim badge, the
    /// centred counts, the caret position, and the note's own shape —
    /// `encoding` reads `"UTF-8"`, `lineEnding` reads `"LF"`, both empty
    /// over a PDF or a picture.
    var footerRegions: (badge: NSView, pendingKeys: NSTextField,
                        counts: NSTextField, cursor: NSTextField,
                        encoding: NSTextField, lineEnding: NSTextField,
                        format: NSTextField) {
        (modeBadge, pendingKeysLabel, statusLabel, cursorLabel,
         formatEncodingLabel, formatLineEndingLabel, formatKindLabel)
    }

    /// The badge and pending keys belong to vim mode. Every other region can
    /// be kept or hidden independently in Settings. Zen takes the lot away.
    private func applyFooterVisibility() {
        let hidesStatusBar = isZenMode || !preferences.showsStatusBar
        let isVim = preferences.vimMode
        // A tab with no editor in front has no vim mode to show, whether vim
        // is on or not: the badge says what the tab is instead — "Read-only"
        // for a viewer, "Reading" for a note read rather than edited — and
        // the keys typed so far mean nothing there.
        modeBadge.setStandIn(footerStandIn)
        let showsBadge = isVim || footerStandIn != nil
        countsLeadingToEdge?.isActive = !showsBadge
        countsLeadingToVim?.isActive = showsBadge
        modeBadge.isHidden = hidesStatusBar || !showsBadge
        pendingKeysLabel.isHidden =
            hidesStatusBar || !isVim || footerStandIn != nil || pendingKeysLabel.stringValue.isEmpty
        cursorLabel.isHidden = hidesStatusBar || !preferences.footerShowsCursorPosition
        formatKindLabel.isHidden = hidesStatusBar || !preferences.footerShowsFormat
        formatEncodingLabel.isHidden = hidesStatusBar || !preferences.footerShowsEncoding
        formatLineEndingLabel.isHidden = hidesStatusBar || !preferences.footerShowsLineEndings
        footerTrailingStack.isHidden = hidesStatusBar || (
            !preferences.footerShowsCursorPosition
                && !preferences.footerShowsFormat
                && !preferences.footerShowsEncoding
                && !preferences.footerShowsLineEndings
        )
        // Nothing to count means no label at all, rather than an empty gap.
        statusLabel.isHidden = hidesStatusBar || preferences.footerSegments.isEmpty
        statusSeparator.isHidden = hidesStatusBar
    }

    /// The word the badge wears in place of the vim mode, or nothing while
    /// an editor is in front.
    private var footerStandIn: String? {
        guard let note = currentNote else { return nil }
        if note.kind.isViewer { return "Read-only" }
        return note.previewMode == .reading ? "Reading" : nil
    }

    /// For the tests: what the footer's badge says right now.
    var footerBadgeTitle: String { modeBadge.title }

    private func applyStatusBarLayout() {
        let hidesStatusBar = isZenMode || !preferences.showsStatusBar
        workspaceSplitBottomToStatus?.isActive = !hidesStatusBar
        workspaceSplitBottomToPane?.isActive = hidesStatusBar
        paneBottomToStatus?.isActive = !hidesStatusBar
        paneBottomToContent?.isActive = hidesStatusBar
        applyFooterVisibility()
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
                        format: format, kind: kind,
                        importing: relativeImageImporter(forFileAt: fileURL, kind: kind))
            watchFile(of: note)
        } else {
            note = makeUntitledNote()
        }
        notes.insert(note, at: min(selectedIndex + 1, notes.count))
        selectedIndex = notes.firstIndex { $0 === note } ?? notes.count - 1
        // The first word count of a big file reads this rather than copying
        // the text back out of the storage it has just been put into.
        if note.kind == .text, BigFile.isBig(length: note.storage.length) {
            openedText = (note.id, text)
        }
        writeCache(note)
        installCurrentNote()
        refreshTabs()
        updateStatus()
        refreshImages(force: true)
        flush()
    }

    /// What turns an ordinary relative image link in a file into a chip, for
    /// the two places that fill a note from a file: opening one and reloading
    /// one. A viewer has no text to read links out of, so it gets nothing.
    private func relativeImageImporter(
        forFileAt fileURL: URL, kind: NoteKind
    ) -> NoteText.RelativeImporter? {
        guard kind == .text else { return nil }
        return Sidecar.importer(forFileAt: fileURL, assets: store.assets)
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
        // The note has come from another window, whose controller it was
        // still reporting its file's changes to. From here it is this one's.
        watchFile(of: note)
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
        // A blank untitled tab — no file, nothing typed — is what a window
        // holds when it holds nothing. Closing one that is the only tab is
        // the reader closing the window; closing anything else that is the
        // only tab leaves a blank one behind, so ⌘W held down walks the
        // tabs out one at a time and stops at an empty window, and one more
        // ⌘W is what closes that (decided 2026-09-07).
        let wasBlank = note.fileURL == nil && note.storage.length == 0
        note.stopWatching()
        store.deleteText(for: note.id)
        notes.remove(at: index)

        let closedTheOnlyTab = notes.isEmpty
        if closedTheOnlyTab {
            // A strip is never empty: this keeps a hidden window that gets
            // summoned again coming back blank, exactly as it does today.
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

        // The only tab just closed, and it was already blank: the window
        // goes the way closing the window goes — the title-bar close
        // button's own path, so the registry's decision (hide the last
        // window, close any other for real) and the session write happen
        // exactly as they do there.
        if closedTheOnlyTab && wasBlank {
            window?.performClose(nil)
        }
    }

    private func confirmDiscard(_ note: Note) -> NSApplication.ModalResponse {
        if let confirmDiscardOverrideForTesting { return confirmDiscardOverrideForTesting() }
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
        // And the key that put the prompt up: ⌘W pressed again on the sheet
        // is Don't Save, so a tab is closed by two strokes of the same key
        // and no reach for the mouse. Whatever Close Tab is bound to.
        let closeCombo = preferences.combo(for: .closeTab)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === alert.window,
                  KeyCombo.recorded(from: event) == closeCombo else { return event }
            dontSave.performClick(nil)
            return nil
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
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
        // A tab owing a name asks for one: ⌘S on a `.txt` the reader has
        // called Markdown is the Save As flow, with `md` offered in the
        // combo and every other extension still there to pick instead.
        if destination == nil || forcePanel || note.needsSaveAs {
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
        //
        // Every chip's picture goes into `<basename>.assets/` beside the file
        // as the text is written out, and its token becomes the ordinary
        // relative link that folder makes readable anywhere else.
        let sidecar = Sidecar.Writer(
            fileURL: destination, assets: store.assets,
            remembered: note.sidecarPaths, rememberedBase: note.sidecarBaseDirectory
        )
        let encoded = TextFile.encode(
            NoteText.serialize(note.storage, sidecar: sidecar.link(forAssetID:)),
            format: note.format
        )
        do {
            try encoded.data.write(to: destination, options: .atomic)
        } catch {
            presentFailure("Couldn’t save “\(destination.lastPathComponent)”.", error)
            return false
        }

        // Where each picture ended up, so the next save writes the same links
        // rather than a second copy of everything.
        note.sidecarPaths = sidecar.paths
        note.sidecarBaseDirectory = destination.deletingLastPathComponent()
        note.format = encoded.format
        note.fileURL = destination
        // The name says it now. A note the footer was reading as JSON, saved
        // as `.json`, has nothing left to override — the extension is the
        // authority again, and a later Save As is free to change what the tab
        // is. One saved as `.txt` while the reader asked for JSON keeps its
        // word: they said what it is, and a file name did not unsay it.
        if note.formatOverride == NoteFormat.ofFile(destination) { note.formatOverride = nil }
        // The name has been asked about and answered, whichever way it went:
        // saved as `.txt` on purpose, the override stands and the next ⌘S
        // writes over this file rather than asking again.
        note.needsSaveAs = false
        note.isDirty = false
        // The file is now exactly what the tab holds, whoever else had
        // written it: the offer and its ring go, and the stamp Nota has just
        // made is recorded so the event this write sets off finds nothing
        // moved and reloads nothing.
        note.hasExternalChange = false
        note.externalChangeOffer = false
        note.recordDiskStamp()
        if note === currentNote { externalChangePill.setShown(false) }
        preferences.lastSaveDirectory = destination.deletingLastPathComponent()
        refreshTabs()
        // Save As can change whether this tab is Markdown at all, and it can
        // change whether it is prose — an untitled note is prose until it is
        // given a name, and `Untitled` saved as `notes.log` is not.
        if note === currentNote {
            applyPreviewMode()
            updateModeControlOverlays()
            // And the badge saying what the tab is read as: the name it has
            // just been given may be the whole answer now.
            updateStatus()
            textView.isContinuousSpellCheckingEnabled =
                SpellCheckPolicy.shouldCheck(url: note.fileURL, length: note.storage.length)
        }
        flushAll()
        return true
    }

    private func runSavePanel(for note: Note) -> URL? {
        if let savePanelProvider { return savePanelProvider(note) }
        return presentSavePanel(for: note)
    }

    /// Nota's own dialog, not `NSSavePanel` (SPEC Done 51): a sheet on this
    /// window, run to its end here so `save(note:forcePanel:)` and everything
    /// that calls it still see one synchronous `URL?`.
    /// The badge goes first: a tab the footer is showing as JSON opens on
    /// `json`, whether it is a new note or a `.txt` the reader has just said
    /// that about — the choice is made and there is no second decision, and
    /// every other extension is still one click away in the same popup.
    private func presentSavePanel(for note: Note) -> URL? {
        guard let window else { return nil }
        let dialog = SaveDialog(
            suggestedName: SuggestedName.panelName(for: note.fileURL, text: note.countableText),
            existingFileURL: note.fileURL,
            lastDirectory: preferences.lastSaveDirectory,
            lastExtension: preferences.lastSaveExtension,
            preferredExtension: note.formatOverride?.canonicalExtension
        )
        dialog.confirmReplace = { [weak self] url in self?.confirmReplace(url) ?? false }
        guard let url = dialog.runSheet(on: window) else { return nil }
        // Next save opens where this one landed, offering the same extension.
        preferences.lastSaveDirectory = url.deletingLastPathComponent()
        if let chosen = SaveNameComposer.split(name: url.lastPathComponent).extension {
            preferences.lastSaveExtension = chosen
        }
        return url
    }

    /// The "already exists, replace?" alert, raised for the destination the
    /// Save dialog composed — real unless a test hands in something else, the
    /// same way `confirmDiscard` does.
    private func confirmReplace(_ url: URL) -> Bool {
        if let confirmReplaceOverrideForTesting { return confirmReplaceOverrideForTesting(url) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: L10n.text("“%@” already exists. Do you want to replace it?",
                              chinese: "“%@”已存在，是否替换？"),
            url.lastPathComponent
        )
        alert.informativeText = L10n.text(
            "A file with this name already exists in this location. Replacing it will overwrite its current contents.",
            chinese: "此位置已存在同名文件，替换后将覆盖其当前内容。"
        )
        alert.addButton(withTitle: L10n.text("Replace", chinese: "替换"))
        alert.addButton(withTitle: L10n.text("Cancel", chinese: "取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Export

    /// Whether File › Export… means anything on the tab in front — what the
    /// menu greys the item out by. Every tab Nota can already write something
    /// for says yes: a render, a listing, a rich-text document, a picture.
    /// An empty window says no, and so, until their exporters are plugged in,
    /// do the two tabs whose only target is somebody else's hook (a document
    /// into a book, a book onto pages).
    var canExportCurrentTab: Bool {
        guard let note = currentNote else { return false }
        return !Exporter.targets(for: note).isEmpty
    }

    /// ⇧⌘E. Ask what shape, ask where, write it, and open what was written
    /// in a tab beside the source (SPEC "## Export", Todo 1).
    ///
    /// Available in every mode: the export is about the tab, not about which
    /// half of it is on screen.
    func exportCurrentTab() {
        guard let note = currentNote else { return }
        let targets = Exporter.targets(for: note)
        guard !targets.isEmpty else { return }
        guard let choice = runExportSheet(for: note, targets: targets) else { return }
        // Answered once and remembered, the way the save panel's own format
        // is: the next export opens on whichever way the pictures went last.
        preferences.exportEditorImages = choice.images
        guard let destination = runExportSavePanel(for: note, target: choice.target) else {
            return
        }
        do {
            try Exporter.export(
                note, to: choice.target, at: destination,
                context: exportContext(images: choice.images)
            )
        } catch {
            // The quiet word in the footer every other failure that is not
            // the reader's fault gets. Nothing here is worth an alert.
            showFooterMessage(String(
                format: L10n.text("Couldn’t export “%@”."), destination.lastPathComponent
            ))
            return
        }
        // Through the same door a file dropped on the strip comes in by, so
        // the written file becomes whatever kind of tab it is, beside the
        // tab it came from, selected.
        open(url: destination)
    }

    private func runExportSheet(for note: Note, targets: [ExportTarget]) -> ExportChoice? {
        if let exportSheetProvider { return exportSheetProvider(note, targets) }
        guard let window else { return nil }
        let dialog = ExportDialog(targets: targets, images: preferences.exportEditorImages)
        return dialog.runSheet(on: window)
    }

    /// Where the export lands: Nota's own Save dialog again, opened on the
    /// tab's own name with the target's extension in place of the note's —
    /// a Markdown note exports as `notes.pdf`, not as `notes.md`.
    ///
    /// The extension is the target's and is not remembered as the last save
    /// extension: exporting as PDF must not offer `pdf` the next time the
    /// note itself is saved.
    private func runExportSavePanel(for note: Note, target: ExportTarget) -> URL? {
        if let savePanelProvider { return savePanelProvider(note) }
        guard let window else { return nil }
        let base = SaveNameComposer.split(name: note.title).base
        let dialog = SaveDialog(
            suggestedName: base + "." + target.fileExtension,
            existingFileURL: note.fileURL,
            lastDirectory: preferences.lastSaveDirectory,
            lastExtension: target.fileExtension,
            preferredExtension: target.fileExtension
        )
        dialog.confirmReplace = { [weak self] url in self?.confirmReplace(url) ?? false }
        guard let url = dialog.runSheet(on: window) else { return nil }
        preferences.lastSaveDirectory = url.deletingLastPathComponent()
        return url
    }

    /// What the export needs to know about this window: the editor's font and
    /// paragraph shape, the store the chips' pictures live in, whether the
    /// gutter is on, and — for an exporter whose answer is on screen rather
    /// than in the note, such as a dump's rows — the pane the tab is being
    /// read through.
    private func exportContext(images: ExportImagePlacement) -> Exporter.Context {
        var context = Exporter.Context(
            font: preferences.font(),
            paragraphStyle: preferences.paragraphStyle(),
            assets: store.assets,
            showsLineNumbers: preferences.showsLineNumbers,
            images: images
        )
        context.previewContent = currentNote.map { previewColumn.content(for: $0) }
        return context
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

    /// Files let go on one of the window's tab targets — the strip, or the
    /// band across the top where a hidden strip would be. Nothing is
    /// filtered on the way in: a picture dropped here is a picture tab, the
    /// same as it would be through ⌘O, and `open(url:)` alone decides which
    /// kind each file becomes.
    func openDroppedFiles(_ urls: [URL]) {
        for url in urls { open(url: url) }
    }

    func open(url: URL) {
        let target = url.standardizedFileURL
        if let index = notes.firstIndex(where: { $0.fileURL?.standardizedFileURL == target }) {
            noteRecentDocument(target)
            selectTab(at: index)
            return
        }
        // The bytes decide what the file is before its name gets a say: a
        // PDF opens as one, a picture as one, a rich-text document as one,
        // and text opens as text, whatever any of them is called.
        switch FileSniff.classify(at: target) {
        case .pdf:
            noteRecentDocument(target)
            addTab(fileURL: target, kind: .pdf)
        case .image:
            noteRecentDocument(target)
            addTab(fileURL: target, kind: .image)
        case .epub:
            noteRecentDocument(target)
            addTab(fileURL: target, kind: .epub)
        case .rtf:
            noteRecentDocument(target)
            addTab(fileURL: target, kind: .rtf)
        case .text:
            openAsText(target)
        case .binary:
            // Not text, and none of the signatures — but a file actually
            // named for a PDF or a picture still gets a tab. PDFKit or
            // `NSImage` may yet make sense of it; if neither does, that is
            // the pane's own missing message, not this alert.
            if let kind = Note.viewerKind(target) {
                noteRecentDocument(target)
                addTab(fileURL: target, kind: kind)
            } else {
                presentFailure("Couldn’t open “\(target.lastPathComponent)”.",
                               nil, detail: "Nota only opens text files.")
            }
        case .unreadable:
            // Nothing about the file could be read at all — missing, or no
            // permission — so the name is all that is left to say what it
            // was going to be. Not a successful open, so the recent list
            // does not learn about it.
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
        noteRecentDocument(target)
        addTab(fileURL: target, text: opened.text, format: opened.format)
        // The setting is about opening files, not about restoring them: a tab
        // coming back from the session keeps the mode it was left in.
        if preferences.opensMarkdownInReadingMode, Note.supportsRenderedPreview(target) {
            setPreviewMode(.reading)
        }
    }

    /// File › Open Recent's list, kept by `NSDocumentController` rather than
    /// Nota's own session: every named-file open funnels through `open(url:)`
    /// or `openAsText`, so this is the one place that has to say so. Session
    /// restore never calls either — a tab coming back on launch is not a
    /// reason to reorder what the reader chose to open by hand.
    private func noteRecentDocument(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    private func presentFailure(_ message: String, _ error: Error?, detail: String? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail ?? error?.localizedDescription ?? ""
        alert.runModal()
    }

    // MARK: - External changes

    /// Every note this window holds watches its own file; this is what the
    /// window does about it. Set wherever a note arrives — opened, restored,
    /// or moved in from another window — which is how, with several windows
    /// open, only the one actually holding the tab reacts.
    private func watchFile(of note: Note) {
        note.onFileChanged = { [weak self, weak note] in
            guard let self, let note else { return }
            self.fileDidChangeOnDisk(note)
        }
    }

    /// A watched file really has changed — the note's stamp said so before
    /// this was called, which is what keeps Nota's own ⌘S from reloading
    /// itself. What happens next is the tab's own business.
    ///
    /// A viewer and a clean note take the new bytes without a word: there is
    /// nothing in either that is not on disk already. A note with edits of
    /// its own is marked instead, and offered the choice the next time it is
    /// what the reader is looking at.
    private func fileDidChangeOnDisk(_ note: Note) {
        defer { onExternalChangeForTesting?() }
        guard notes.contains(where: { $0 === note }) else { return }
        guard note.kind == .text else {
            reloadViewer(note)
            return
        }
        guard note.isDirty else {
            reloadFromDisk(note)
            return
        }
        note.hasExternalChange = true
        note.externalChangeOffer = true
        refreshTabs()
        showExternalChangeOfferIfOwed()
    }

    /// A PDF or a picture whose file has been written again. It is never
    /// dirty and there is nothing to ask about: the parsed document goes, and
    /// the column reads the file afresh.
    private func reloadViewer(_ note: Note) {
        note.discardLoadedContent()
        guard note === currentNote else { return }
        previewColumn.content(for: note).invalidateRender()
        refreshPreviewContent()
        updateStatus()
    }

    /// The file's text, put into the tab in place of what was there, with the
    /// caret and the scroll position kept as near as the new text allows —
    /// the caret's offset clamped to the shorter of the two texts, and the
    /// scroll held at the same point down the document unless the file has
    /// grown shorter than that. The format is re-read as well: a file
    /// rewritten as CRLF, or in another encoding, is saved back the way it is
    /// now rather than the way it was opened.
    ///
    /// The undo history goes. It is a list of ranges into text that is no
    /// longer there, and undoing over a reload would be undoing into another
    /// file.
    @discardableResult
    private func reloadFromDisk(_ note: Note) -> Bool {
        guard note.kind == .text, let url = note.fileURL,
              let opened = TextFile.read(at: url) else { return false }
        let isFront = note === currentNote
        let caret = isFront ? textView.selectedRange().location : note.selectionLocation
        let scrollOrigin = isFront ? scrollView.contentView.bounds.origin : .zero

        if isFront { isSwappingNote = true }
        // Read the same way an open reads it: the file's own relative image
        // links are chips again, and the paths behind them are what the next
        // save writes back.
        let rendered = NoteText.render(
            opened.text, attributes: defaultAttributes, assets: store.assets,
            importing: relativeImageImporter(forFileAt: url, kind: note.kind)
        )
        note.storage.setAttributedString(rendered.text)
        note.sidecarPaths = rendered.relativePaths
        note.sidecarBaseDirectory = url.deletingLastPathComponent()
        note.format = opened.format
        note.isDirty = false
        note.hasExternalChange = false
        note.externalChangeOffer = false
        note.recordDiskStamp()
        note.undoManager.removeAllActions()
        note.selectionLocation = min(max(0, caret), note.storage.length)

        if isFront {
            textView.setSelectedRange(
                NSRange(location: note.selectionLocation, length: 0)
            )
            isSwappingNote = false
            externalChangePill.setShown(false)
            restoreScroll(to: scrollOrigin)
            lineNumberRuler?.refresh()
            vimEngine.refreshSearchHighlights()
            previewColumn.content(for: note).invalidateBlocks()
            refreshPreviewContent()
            updateStatus()
            updateCursorPosition()
            refreshImages(force: true)
        }
        writeCache(note)
        refreshTabs()
        flush()
        return true
    }

    /// Puts the editor back where it was looking. The document may be shorter
    /// than it was, so the offset is clamped to whatever room is left.
    private func restoreScroll(to origin: NSPoint) {
        guard let documentView = scrollView.documentView else { return }
        let lowest = max(0, documentView.frame.height - scrollView.contentSize.height)
        scrollView.contentView.scroll(
            to: NSPoint(x: origin.x, y: min(max(0, origin.y), lowest))
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Reload, pressed. The tab in front takes the file's text and stops
    /// being dirty.
    private func reloadFrontNoteFromDisk() {
        externalChangePill.setShown(false)
        guard let note = currentNote else { return }
        reloadFromDisk(note)
    }

    /// The offer a marked tab is owed, put up whenever that tab is the one in
    /// front of this window — which is what "the next time it gets focus"
    /// comes to: a tab behind shows it when it is chosen, and a tab in front
    /// of a window that is behind has it up already, waiting, for the moment
    /// the window is looked at.
    ///
    /// The debt is not put down by showing it. It is put down by answering it
    /// — Reload, Keep mine, a save, a reload — so a tab switched away from
    /// and back to still asks, and only that. A further change on disk sets
    /// the same flag again and changes nothing else, which is what keeps a
    /// file being written every second from becoming a storm.
    private func showExternalChangeOfferIfOwed() {
        guard let note = currentNote, note.kind == .text,
              note.isDirty, note.externalChangeOffer
        else { return }
        // The file speaking up is the louder news, and both offers stand in
        // the same corner: Nota's reading of the text can wait.
        cancelFormatOffer()
        externalChangePill.setShown(true)
    }

    /// The offer, for the tests: whether it is up, and the two words to press.
    var externalChangeOffer: ExternalChangePill { externalChangePill }

    // MARK: - Persistence

    /// Debounced: fires ~300 ms after the last edit — 2 s for a big note,
    /// since `flush` serializes and writes the whole thing to the cache, and
    /// that must not land in the middle of the next keystroke.
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        saveWorkItem = item
        let isBig = currentNote.map { BigFile.isBig(length: $0.storage.length) } ?? false
        let delay = isBig ? 2.0 : 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Writes the visible tab's text plus `session.json`.
    private func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        if let note = currentNote {
            rememberSelection(note)
            writeCache(note)
        }
        writeSessionFile()
    }

    /// Writes every tab. Used on tab switch, window close and termination.
    func flushAll() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        currentNote.map(rememberSelection)
        for note in notes { writeCache(note) }
        writeSessionFile()
    }

    /// One tab's text into the cache.
    ///
    /// The snapshot is taken here, on the main thread — that copy is what a
    /// note *is*, and there is no getting round it. Writing it out is another
    /// matter: a hundred megabytes through the file system is not something
    /// the run loop can be asked for between keystrokes, so a big note's
    /// write goes to the cache queue and the pause it would have caused goes
    /// with it. An ordinary note is written where it always was, on the spot,
    /// so the cache is already on disk when the next line of a test reads it.
    ///
    /// `session.json` stays on the main thread either way: it is small, and
    /// it is the file that says which of these tabs exists at all.
    private func writeCache(_ note: Note) {
        guard note.writesToCache else { return }
        let text = note.text
        let id = note.id
        guard BigFile.isBig(length: note.storage.length) else {
            return store.writeText(text, for: id)
        }
        let store = store
        cacheWrites.async { store.writeText(text, for: id) }
    }

    /// Waits for every cache write that has been asked for. The app calls it
    /// on the way out, where a write still in the air would be a write lost;
    /// nothing else has to, since the queue drains on its own.
    func drainCacheWrites() {
        cacheWrites.sync { }
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
        // And how far down it, for the content that has somewhere to be
        // inside the place it is remembering — a chapter of a book.
        if let scroll = previewColumn.content(for: note).rememberedScroll {
            note.scrollFraction = scroll
        }
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
            store.save(SessionState(windows: [sessionWindow], fontSize: Double(fontSize),
                                    bookmarks: bookmarks.paths))
            return
        }
        sessionWriter()
    }

    // MARK: - Font size and zoom

    /// Writes through to `Preferences`; the change notification restyles the
    /// editor and moves the Settings window's stepper.
    func setFontSize(_ size: CGFloat) {
        preferences.fontSize = size
    }

    var currentFontSize: CGFloat { fontSize }

    /// Whether ⌘+ / ⌘- / ⌘0 zoom the content in the column rather than change
    /// the editor's font size.
    ///
    /// The rule is which of the two the reader can actually see. With an
    /// editor on screen — any text tab in edit or split — the keys are the
    /// font's, and the Markdown and LaTeX renders follow it as they always
    /// have. With the content alone on screen they are the content's, unless
    /// the content is a render, where the font already *is* the zoom.
    /// What the tab asks for rather than what is installed: a mode change
    /// slides, and the keys are the reader's the moment they ask for the
    /// mode rather than a fifth of a second later.
    var zoomsContent: Bool {
        guard previewMode == .reading, let note = currentNote else { return false }
        return previewColumn.content(for: note).canZoom
    }

    /// What the View menu's first two size items are called on the tab in
    /// front. They are one pair of hands doing two jobs, so they say which
    /// job it is; "Actual Size" is the name of both and stays put.
    var sizeMenuTitles: (increase: String, decrease: String) {
        zoomsContent
            ? ("Zoom In", "Zoom Out")
            : ("Increase Font Size", "Decrease Font Size")
    }

    /// One press of ⌘+ or ⌘-. A quarter more or less each time, which is the
    /// step every document reader takes.
    private static let zoomStep: CGFloat = 1.25

    func zoomIn() {
        guard zoomsContent else { return setFontSize(currentFontSize + 1) }
        zoomContent(by: Self.zoomStep)
    }

    func zoomOut() {
        guard zoomsContent else { return setFontSize(currentFontSize - 1) }
        zoomContent(by: 1 / Self.zoomStep)
    }

    /// ⌘0. Back to the editor's own 13pt, or — where the keys are the
    /// content's — back to however the content draws itself: a page fitted to
    /// the column, a picture fitted to it, an HTML page at 100%.
    func actualSize() {
        guard zoomsContent else { return setFontSize(13) }
        setContentZoom(1)
    }

    private func zoomContent(by factor: CGFloat) {
        guard let note = currentNote else { return }
        setContentZoom(previewColumn.content(for: note).zoom * factor)
    }

    /// The content clamps what it is handed, so what it settled on is what the
    /// tab remembers — not what was asked for.
    private func setContentZoom(_ zoom: CGFloat) {
        guard let note = currentNote else { return }
        var content = previewColumn.content(for: note)
        content.zoom = zoom
        note.previewZoom = content.zoom
        previewColumn.noteZoomChanged()
    }

    /// The content zoomed itself — a pinch on a document. Where the reader
    /// left it is the tab's, the same as the page they left it on.
    private func previewZoomDidChange(_ zoom: CGFloat) {
        currentNote?.previewZoom = zoom
        previewColumn.noteZoomChanged()
    }

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

    /// File › Reveal in Finder is offered only when there is a file to show.
    var currentTabHasFile: Bool { currentNote?.fileURL != nil }

    /// What "Reveal in Finder" actually does with the file. The Finder is
    /// the default; a test puts its own hand here and reads what arrived,
    /// since bringing the Finder forward is not a thing a test should do.
    var fileRevealer: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }

    /// Shows the tab's file in a Finder window, selected. Nothing for an
    /// untitled note: there is no file, and the menu item was greyed.
    func revealInFinder(at index: Int) {
        guard notes.indices.contains(index), let url = notes[index].fileURL else { return }
        fileRevealer([url])
    }

    func revealCurrentTabInFinder() {
        revealInFinder(at: selectedIndex)
    }

    // MARK: Bookmarks

    /// Whether the tab in front is bookmarked — the title File › Bookmarks ▸
    /// Bookmark and the tab's context menu are written with.
    var currentTabIsBookmarked: Bool {
        currentNote?.fileURL.map(bookmarks.contains) ?? false
    }

    /// Whether ⌘D means anything here. Any tab does — a PDF and a picture
    /// are files worth coming back to, and an untitled note is asked for a
    /// name first — so this is only about there being a tab at all.
    var canBookmarkCurrentTab: Bool { currentNote != nil }

    /// ⌘D, and "Bookmark" / "Remove Bookmark" in the tab's context menu.
    func toggleBookmarkForCurrentTab() {
        guard notes.indices.contains(selectedIndex) else { return }
        toggleBookmark(at: selectedIndex)
    }

    /// A bookmark is a path, so a note that has never been saved has nothing
    /// to bookmark: ⌘D asks it to be saved first, and a cancelled panel
    /// leaves the note exactly as unbookmarked as it was.
    func toggleBookmark(at index: Int) {
        guard notes.indices.contains(index) else { return }
        let note = notes[index]
        if note.fileURL == nil {
            guard save(note: note, forcePanel: false), note.fileURL != nil else { return }
        }
        guard let url = note.fileURL else { return }
        bookmarks.toggle(url)
        refreshTabs()
        writeSessionFile()
    }

    /// Choosing a bookmark, from the menu or either picker list. The file
    /// this window already has open is a tab switch; anything else is an
    /// ordinary open, which is also what puts it in Open Recent.
    func openBookmark(path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if let index = notes.firstIndex(where: { $0.fileURL?.standardizedFileURL == url }) {
            selectTab(at: index)
            focusEditor()
            return
        }
        open(url: url)
    }

    func removeBookmark(path: String) {
        bookmarks.remove(path: path)
        refreshTabs()
        writeSessionFile()
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
            modeBadge, pendingKeysLabel, footerTrailingStack,
        ]

        // The strip's constraints and the traffic lights: zen takes both, and
        // Settings may already have taken either. Split survives zen, so the
        // render column takes the same drop and gets a drag band of its own
        // rather than running to the frame; the footer goes but the pane does
        // not — `:` has to work in zen mode.
        applyTopChrome()

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
            applyStatusBarLayout()
            // And the strip only if Settings has not hidden it on its own,
            // nor parked it off the top waiting for the pointer.
            tabBar.isHidden = preferences.hidesTabBar || preferences.autoHidesTabBar
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

    /// The split's own view, swapped in before the controller loads its
    /// default one, so the divider can be told not to draw. The delegate's
    /// `shouldHideDividerAt` alone is not enough: the controller lays the
    /// divider out regardless and draws it, a 1pt dark line down the window's
    /// edge — right beside the sidebar's own divider when there is one, so
    /// the seam reads as two lines.
    override func loadView() {
        let split = DocumentSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.hidesDivider = { [weak self] in self?.hidesDivider() ?? false }
        splitView = split
        super.loadView()
    }

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

/// The document split's view: a divider that is hidden is not drawn.
final class DocumentSplitView: NSSplitView {
    var hidesDivider: () -> Bool = { false }

    override func drawDivider(in rect: NSRect) {
        guard !hidesDivider() else { return }
        super.drawDivider(in: rect)
    }
}

/// A transparent strip that lets the window be dragged by its top edge once
/// the title bar's own chrome is gone.
///
/// It stands in the band the tab strip would occupy, so it is a tab target
/// too: files let go on it open as tabs, exactly as they would on the strip
/// itself. That is also what saves the auto-hidden strip from having to
/// reveal itself for a drag — the band behind it already takes the drop.
final class DragRegionView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    /// Files dragged in from the Finder and let go on the band.
    var onDropFiles: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.draggedFileURLs.isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.draggedFileURLs.isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.draggedFileURLs
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }
}

/// The band across the very top of the window that an auto-hidden tab strip
/// waits behind. It draws nothing and takes no clicks — hit testing goes
/// straight through it to the document underneath — so the only thing it is
/// for is the tracking area: the pointer arriving, and the pointer leaving.
final class TabBarHotZoneView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    // A pointer already sitting in the band when the band appears never
    // enters it, so a move inside counts as an arrival too.
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseMoved(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
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

/// One clickable half of the footer's format field — `UTF-8` or `LF` — as a
/// capsule in the vim badge's own family, so it reads as something to press
/// rather than a word that happens to be there. The click pops the menu, and
/// hover only brightens the capsule: nothing in the footer opens on hover.
private final class FooterMenuLabel: NSTextField {
    var onClick: (() -> Void)?
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    init() {
        super.init(frame: .zero)
        cell = FooterBadgeCell(textCell: "")
        isEditable = false
        isSelectable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        lineBreakMode = .byClipping
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        // An empty field — a PDF or a picture — is no field at all.
        if !stringValue.isEmpty {
            NSColor.labelColor.withAlphaComponent(isHovered ? 0.12 : 0.06).setFill()
            NSBezierPath(
                roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2
            ).fill()
        }
        super.draw(dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The badge's cell: the vim chip's 18pt height and 8pt of air either side
/// of the word, the word itself centred in the capsule. Empty, it takes no
/// room at all.
private final class FooterBadgeCell: NSTextFieldCell {
    static let height: CGFloat = 18
    static let horizontalPadding: CGFloat = 8

    override var cellSize: NSSize {
        guard !stringValue.isEmpty else { return .zero }
        var size = super.cellSize
        size.width += Self.horizontalPadding * 2
        size.height = Self.height
        return size
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let textHeight = super.cellSize.height
        let inset = rect.insetBy(dx: Self.horizontalPadding, dy: 0)
        return NSRect(
            x: inset.minX, y: inset.midY - textHeight / 2,
            width: inset.width, height: textHeight
        )
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
    /// A word that stands in for the vim mode while the tab in front has no
    /// editor to be in a mode of: "Read-only" over a PDF, a picture, a book
    /// or an RTF, "Reading" over a note in reading mode. `nil` gives the
    /// badge back to vim.
    private(set) var standIn: String?

    /// What the badge is showing, for the tests.
    var title: String { label.stringValue }

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

    /// Puts a word in the vim mode's place, or takes it away again. No
    /// cross-fade: this changes with the tab, and the tab is already a cut.
    func setStandIn(_ word: String?) {
        guard word != standIn else { return }
        standIn = word
        applyMode()
    }

    private func applyMode() {
        label.stringValue = standIn ?? mode.badgeTitle
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

    /// The ⇧⌘J panel itself, for the tests to type at.
    var tabPickerPanel: TabPickerPanel { tabPicker }
    /// The strip's Bookmark button as it stands: its symbol, whether it can
    /// be pressed, and its tip.
    var stripBookmarkButtonForTesting: (symbol: String?, isEnabled: Bool, toolTip: String?) {
        tabBar.bookmarkToggleStateForTesting
    }

    /// ⇧⌘J.
    func showTabPicker() {
        guard let window else { return }
        showWindow(nil)
        tabPicker.show(
            titles: notes.map(\.title),
            symbolNames: notes.map { $0.iconSymbolName },
            bookmarkedTabs: bookmarkedTabs,
            selectedIndex: selectedIndex,
            bookmarks: unopenedBookmarks,
            missingBookmarks: Set(bookmarks.missingPaths),
            loadHeadings: { [weak self] completion in
                self?.loadFrontTabHeadings(completion: completion)
            },
            over: window
        )
    }

    /// The bookmark button in the strip: the same panel, listing bookmarks
    /// alone.
    func showBookmarksPicker() {
        guard let window else { return }
        showWindow(nil)
        tabPicker.showBookmarks(
            bookmarks: bookmarks.paths,
            missingBookmarks: Set(bookmarks.missingPaths),
            frontTab: (
                canBookmark: canBookmarkCurrentTab, isBookmarked: currentTabIsBookmarked
            ),
            over: window
        )
    }

    /// Which open tabs are bookmarked, in tab order: what the picker draws
    /// each row's kind icon filled by. An untitled tab has no file and so is
    /// never one.
    var bookmarkedTabs: [Bool] {
        notes.map { note in
            guard let url = note.fileURL else { return false }
            return bookmarks.contains(url)
        }
    }

    /// What ⇧⌘J offers under the open tabs: the bookmarks this window does
    /// not already have a tab for. One that is open is reachable as a tab,
    /// and listing it twice would only make the list longer.
    private var unopenedBookmarks: [String] {
        let open = Set(notes.compactMap { $0.fileURL?.standardizedFileURL.path })
        return bookmarks.paths.filter { !open.contains($0) }
    }

    /// `@` in the switcher (Todo 9): the front `.md` tab's headings, read
    /// from its own text rather than the render. A note past
    /// `BigFile.threshold` is scanned on a background queue so the panel
    /// never waits on the run loop for it; an ordinary note answers on the
    /// spot, the same call either way.
    private func loadFrontTabHeadings(completion: @escaping ([MarkdownHeadings.Heading]) -> Void) {
        // A book has no headings here: its own table of contents is the
        // sidebar's, where it can stay on screen while the chapter is read,
        // rather than a list that closes the moment one is chosen.
        guard let note = currentNote, note.previewKind == .markdown else {
            completion([])
            return
        }
        if BigFile.isBig(length: note.storage.length) {
            let snapshot = note.storage.string
            DispatchQueue.global(qos: .userInitiated).async {
                let headings = MarkdownHeadings.extract(from: snapshot)
                DispatchQueue.main.async { completion(headings) }
            }
        } else {
            completion(MarkdownHeadings.extract(from: note.storage.string))
        }
    }
}

extension MainWindowController: TabPickerPanelDelegate {
    func tabPicker(_ picker: TabPickerPanel, didChoose tabIndex: Int) {
        selectTab(at: tabIndex)
        focusEditor()
    }

    func tabPicker(_ picker: TabPickerPanel, didChooseHeading heading: MarkdownHeadings.Heading) {
        goToHeading(heading)
    }

    /// The switcher's "Add new tab" row: exactly what ⌘T does.
    func tabPickerDidRequestNewTab(_ picker: TabPickerPanel) {
        newTab()
        focusEditor()
    }

    /// The bookmarks panel's top row: exactly what ⌘D does, Save As for an
    /// untitled note included.
    func tabPickerDidRequestBookmarkCurrentTab(_ picker: TabPickerPanel) {
        // A note with no file is asked for a name first, and that is a modal
        // panel. Run from inside the picker's own click — a table's action,
        // sent while its mouse tracking is still going, in a non-activating
        // panel that has just ordered itself out — the panel never came up
        // and the row stayed lit as if nothing had been pressed. The next
        // turn of the run loop is after all of that has settled. (Scheduled
        // on the run loop rather than the main queue: a nested run — a
        // test's, a modal's — turns run-loop blocks and leaves queued ones.)
        guard currentTabHasFile else {
            RunLoop.main.perform { [weak self] in self?.toggleBookmarkForCurrentTab() }
            return
        }
        toggleBookmarkForCurrentTab()
    }

    func tabPicker(_ picker: TabPickerPanel, didChooseBookmark path: String) {
        openBookmark(path: path)
    }

    func tabPicker(_ picker: TabPickerPanel, didRemoveBookmark path: String) {
        removeBookmark(path: path)
    }

    /// ⇧⌘F's list: the hit's tab comes forward with the match selected.
    func tabPicker(
        _ picker: TabPickerPanel, didChooseSearchMatch match: NoteSearchMatch, query: String
    ) {
        reveal(match, query: query)
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

    /// ⌘P. Editor → split → reading → split → editor: split is the middle,
    /// and from it the key moves on from wherever the tab came, so one press
    /// undoes the last and the render never jumps from full to gone. The
    /// mode belongs to the tab, not to the app: a Markdown note keeps it —
    /// across relaunches, through the session — while the next ⌘T opens in
    /// the editor.
    func toggleMarkdownPreview() {
        switch previewMode {
        case .off, .reading:
            setPreviewMode(.split)
        case .split:
            setPreviewMode(currentNote?.modeBeforeSplit == .reading ? .off : .reading)
        }
    }

    /// ⇧⌘P. Straight to the render, and straight back out of it.
    func toggleReadingMode() {
        setPreviewMode(previewMode == .reading ? .off : .reading)
    }

    /// The one way the mode ever changes: the menu, ⌘P, either column's
    /// control, a block click and a keystroke in reading mode all come
    /// through here.
    func setPreviewMode(_ mode: PreviewMode) {
        guard let note = currentNote, note.supportsRenderedPreview else { return }
        if mode == .split, note.previewMode != .split { note.modeBeforeSplit = note.previewMode }
        note.previewMode = mode
        applyPreviewMode(animated: true)
        refreshPreviewContent()
        updatePreviewModeControl()
        updateModeControlOverlays()
        // The badge says "Reading" while the editor is away, and the vim
        // word again the moment it is back.
        applyFooterVisibility()
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
        // lands, and a key held on ⌘P arrives as two slides rather than
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
            thawEditorWrapWidth()
            updateModeControlOverlays()
            return
        }

        // The render on screen is the one that slides: it is made now, at the
        // width it is leaving, so the animation itself has no work in it — no
        // render, no forced layout, nothing per frame.
        previewModeIsSliding = true
        refreshPreviewContent()
        // The render rides the animation at the width it was made for, rather
        // than re-wrapping itself on every frame of it — and the editor rides
        // it the same way, so word wrap does not re-flow the note on every
        // frame the divider narrows it by.
        _ = previewColumn.freezeWidth()
        freezeEditorWrapWidth()
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
        thawEditorWrapWidth()
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
    /// How far down the place the front tab is remembering the reader had
    /// got — a book's chapter, and 0 for everything else. Its own accessor
    /// rather than a fourth member of `currentTabState`, which every other
    /// suite already destructures by name.
    var currentTabScroll: Double { currentNote?.scrollFraction ?? 0 }

    /// Where the front tab was left inside its own database — the table the
    /// grid was showing and the question beside it. Here for the same reason
    /// `currentTabScroll` is: a session field a test has no other way to see.
    var currentTabDatabase: (table: String?, query: String?) {
        (currentNote?.sqlTable, currentNote?.sqlQuery)
    }

    /// What the front tab is read as, and whether that is the reader's own
    /// word or the file name's — the two halves of the footer's format badge,
    /// for the tests.
    var currentTabFormat: (effective: NoteFormat, override: NoteFormat?, needsSaveAs: Bool) {
        (currentNote?.effectiveFormat ?? .plainText, currentNote?.formatOverride,
         currentNote?.needsSaveAs ?? false)
    }

    /// What the Save dialog's Format popup would open on for the front tab —
    /// for the tests, which never put a real dialog up. `SaveDialog`'s own
    /// rule, asked without the dialog.
    var currentSaveExtension: String {
        SaveDialog.openingExtension(
            existingFileURL: currentNote?.fileURL,
            lastExtension: preferences.lastSaveExtension,
            preferredExtension: currentNote?.formatOverride?.canonicalExtension
        )
    }

    var currentTabState: (kind: NoteKind, isDirty: Bool, selection: Int) {
        let note = currentNote
        return (note?.kind ?? .text, note?.isDirty ?? false, note?.selectionLocation ?? 0)
    }

    /// The preview column's content views and which of them is on screen —
    /// for the tests. Exactly one is ever showing, and a PDF tab is the only
    /// thing that puts the document there.
    var previewPanes: PreviewPaneView.Panes { previewColumn.panes }

    /// The zoom pill in the preview column's bottom-leading corner — for the
    /// tests, which are the only thing that reaches into it.
    var zoomPill: ZoomPillOverlay { previewColumn.zoomPill }

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

    /// Both overlays' controls follow the tab in front — a tab switch, ⌘P, a
    /// block click, a keystroke in reading mode, a restored session. The tints
    /// go with the selection: the idle segments are the quiet ones.
    private func updatePreviewModeControl() {
        // Asked of each overlay rather than shared: which segment a mode
        // lands on depends on whether that overlay's own tab has a format
        // action standing ahead of the modes.
        for overlay in [editorModeOverlay, previewModeOverlay] {
            let index = overlay.segmentIndex(of: previewMode)
            // The tints are six symbol images built from scratch, so they are
            // laid on only when the selection has actually moved — a control
            // already showing this mode is left alone.
            guard overlay.modeControl.selectedSegment != index else { continue }
            overlay.modeControl.selectedSegment = index
            overlay.applySegmentTints()
        }
    }

    /// What the front tab puts in the corner, asked of the note rather than of
    /// a list of extensions kept here. A tab with a render gets the mode
    /// control; a `.json` or `.html` tab gets that control with its own
    /// Beautify / Compact action on the end; everything else — a `.txt`, an
    /// untitled note, a PDF, a picture, a book — gets nothing, and zen gets
    /// nothing whatever the tab is.
    private var cornerSlotContent: ModeControlOverlay.Content {
        guard !isZenMode, let note = currentNote, note.supportsRenderedPreview
        else { return .none }
        guard let kind = cornerFormatKind else { return .modeControl }
        return .modeControlWithFormat(kind)
    }

    /// Which format the front tab can be laid out both ways, if either. Both
    /// of them have a render behind them now, so the action never stands on
    /// its own — it is always the fourth segment of a mode control.
    private var cornerFormatKind: ModeControlOverlay.FormatKind? {
        guard let note = currentNote else { return nil }
        if note.isJSON { return .json }
        if note.isHTML { return .html }
        return nil
    }

    /// Which columns carry a slot, what is in it, and how far down their
    /// column it sits.
    ///
    /// The slot is per column: the editor's goes in reading, where that column
    /// is collapsed, and the preview's is there in split and reading. Both
    /// carry whatever the tab put in the corner, action segment included.
    ///
    /// A ⌘F bar takes its column's corner but not its control. The control
    /// drops the height of the pill and goes on working underneath it, which
    /// is how the mode stays one hover away while a search is up.
    fileprivate func updateModeControlOverlays() {
        let content = cornerSlotContent
        // In reading the editor column is collapsed, so its slot is empty
        // however the tab would otherwise have filled it.
        editorModeOverlay.setContent(installedPreviewMode == .reading ? .none : content)
        // Worked out on the spot — a tab arriving in front, a file reloaded
        // off disk — unless a re-parse is already on its way, which is what
        // keeps a burst of typing to one walk over the text.
        if content.format != nil, formatSlotWorkItem == nil { refreshFormatSlotState() }
        // Whichever pill stack is standing in the editor's corner — ⌘F's one
        // or two, or ⌘J's one — is what the control clears.
        let editorStack: CGFloat = findSession.isVisible ? findBar.stackHeight
            : (goToLineSession.isVisible ? PillView.height : 0)
        editorModeOverlay.findBarClearance = editorStack > 0
            ? ModeControlOverlay.drop(forFindBarOfHeight: editorStack) : 0
        previewModeOverlay.setContent(installedPreviewMode != .off ? content : .none)
        let preview = previewColumn.current
        previewModeOverlay.findBarClearance = preview.isFindBarVisible
            ? ModeControlOverlay.drop(forFindBarOfHeight: preview.findBarHeight) : 0
    }

    /// Both slots' contents, for the tests.
    var cornerSlotContents: (
        editor: ModeControlOverlay.Content, preview: ModeControlOverlay.Content
    ) {
        (editorModeOverlay.content, previewModeOverlay.content)
    }

    /// Work the corner out again from the front tab — what a tab switch, a
    /// save under a new name or the debounce after typing all come back to.
    func refreshCornerSlot() {
        updateModeControlOverlays()
    }

    // MARK: - The action in the corner

    /// Which way round the action segment points, or the line the parse gave
    /// up on. One linear walk over the text, so it is asked when the tab
    /// changes and on the debounce after typing, never per keystroke.
    ///
    /// Both columns are told: in split a `.json` tab has the same capsule in
    /// each of its two corners, and a segment that said "Beautify" in one and
    /// "Compact" in the other would be a bug you could see.
    private func refreshFormatSlotState() {
        formatSlotWorkItem?.cancel()
        formatSlotWorkItem = nil
        guard let note = currentNote, let kind = cornerFormatKind else { return }
        let state = formatState(of: note.storage.string, as: kind)
        for overlay in [editorModeOverlay, previewModeOverlay] { overlay.setFormatState(state) }
    }

    /// What the formatter says about the text: the shape the file is *not* in,
    /// or the line it could not be read past.
    private func formatState(
        of text: String, as kind: ModeControlOverlay.FormatKind
    ) -> ModeControlOverlay.FormatState {
        switch kind {
        case .json:
            if let line = JSONFormat.errorLine(in: text) { return .invalid(line: line) }
            return .action(JSONFormat.isPretty(text) ? .compact : .beautify)
        case .html:
            if let line = HTMLFormat.errorLine(in: text) { return .invalid(line: line) }
            return .action(HTMLFormat.isPretty(text) ? .compact : .beautify)
        }
    }

    /// The same text the other way round, or `nil` where the formatter will
    /// not have it.
    private func reformatted(
        _ text: String, as action: ModeControlOverlay.FormatAction,
        of kind: ModeControlOverlay.FormatKind
    ) -> String? {
        switch kind {
        case .json:
            return try? JSONFormat.reformat(text, as: action == .beautify ? .pretty : .compact)
        case .html:
            return try? HTMLFormat.reformat(text, as: action == .beautify ? .pretty : .minified)
        }
    }

    /// Typing debounces, on the beat the footer's own counts use: a burst of
    /// keystrokes re-parses once, about half a second after it stops, rather
    /// than once a key.
    private func scheduleFormatSlotRefresh() {
        guard cornerFormatKind != nil else { return }
        formatSlotWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refreshFormatSlotState() }
        formatSlotWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// The action segment was pressed. The whole note is replaced through the
    /// editor's own undoable path — `shouldChangeText` / `didChangeText`, the
    /// way a line operation replaces its lines — so the tab goes dirty, ⌘Z
    /// puts the file back exactly as it was, and the save, vim and the footer
    /// all see one edit rather than a document swapped out from under them.
    ///
    /// The caret goes to the top: every line has moved, so the place it was
    /// no longer means anything, and the top is where a reader starts reading
    /// a file that has just been laid out.
    private func applyFormat(
        _ action: ModeControlOverlay.FormatAction, of kind: ModeControlOverlay.FormatKind
    ) {
        guard let note = currentNote, cornerFormatKind == kind,
              let storage = textView.textStorage, storage === note.storage
        else { return }
        let text = storage.string
        guard let formatted = reformatted(text, as: action, of: kind), formatted != text
        else { return }
        let whole = NSRange(location: 0, length: storage.length)
        guard textView.shouldChangeText(in: whole, replacementString: formatted) else { return }
        storage.replaceCharacters(
            in: whole, with: NSAttributedString(string: formatted, attributes: defaultAttributes)
        )
        // Put the caret down before `didChangeText`, which is where the window
        // writes the selection into the note.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.didChangeText()
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        // The file is now in the other shape, so the segment is the other way
        // round — at once, not half a second later: this one was a click.
        refreshFormatSlotState()
    }

    /// The matches have moved under an open find bar. Debounced like the
    /// render, and for the same reason: a burst of keystrokes re-scans once,
    /// about 150 ms after the typing stops, rather than once per key.
    ///
    /// A big note is left alone. The scan stops at the highlight cap, which
    /// is cheap when the query is finding things — but a query on its way to
    /// nothing is a whole pass over the file, near a tenth of a second per
    /// twenty megabytes, and that is not a thing to do between one keystroke
    /// and the next. The bands there stay as the last search left them until
    /// the reader asks again.
    private func scheduleFindRefresh(for note: Note) {
        findRefreshWorkItem?.cancel()
        findRefreshWorkItem = nil
        guard findSession.isVisible, !BigFile.isBig(length: note.storage.length) else { return }
        let item = DispatchWorkItem { [weak self] in self?.findSession.refresh() }
        findRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
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
        // How close this tab was being read at. The content clamps it, so
        // what it settled on goes back into the tab.
        var content = previewColumn.content(for: note)
        content.zoom = note.previewZoom
        note.previewZoom = content.zoom
        // The pill says the tab in front's zoom or nothing at all, so a tab
        // or a mode that has no zoom to report takes it away at once.
        previewColumn.refreshZoomPill(zoomsContent: zoomsContent)
        highlightPreviewBlock()
    }

    /// The reader moved somewhere the content in the column is keeping — a
    /// page turned in a PDF. That is where the tab is left, so it goes where a
    /// caret would: into the note, and from there into the session on the same
    /// debounce a keystroke uses.
    private func previewPositionDidChange(_ position: Int) {
        guard let note = currentNote else { return }
        note.selectionLocation = position
        // What the footer says about the content is part of what just moved —
        // a page turned, a chapter turned to — so the answer it is holding is
        // a step behind until it is asked for again.
        previewStatus = currentPreviewFooterStatus
        updateCursorPosition()
        // And the contents column follows the chapter or page that just
        // moved.
        updateContentsSelection()
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

    /// Ticking a checkbox in the render. One character of the note is
    /// rewritten — the space or the `x` between the item's brackets — through
    /// the editor's own undoable path, so ⌘Z puts it back the way it puts any
    /// other edit back. The caret does not move and the editor does not
    /// scroll: the reader is in the render, and a checkbox is not a jump.
    ///
    /// The render then comes back changed the way it does after any keystroke.
    private func toggleTask(inSource source: NSRange) {
        guard let note = currentNote, let storage = textView.textStorage,
              storage === note.storage,
              let box = TaskList.box(in: storage.mutableString, within: source)
        else { return }
        let target = NSRange(location: box.location, length: 1)
        let replacement = box.isDone ? " " : "x"
        guard textView.shouldChangeText(in: target, replacementString: replacement) else { return }
        let caret = textView.selectedRange()
        storage.replaceCharacters(in: target, with: replacement)
        // Put back before `didChangeText`, which is what the window hears the
        // edit through and where the caret would otherwise be written down.
        textView.setSelectedRange(caret)
        textView.didChangeText()
    }

    /// A block was clicked in the pane: the block's own source is selected in
    /// the editor, which then takes the keyboard.
    ///
    /// A jump selects what it jumped to. The reader pointed at a paragraph
    /// and asked to be put in it, and the whole of it selected is the useful
    /// place to arrive: typing replaces the block, ⌘Z puts it back, and an
    /// arrow key collapses the selection to one end of it the way any
    /// selection collapses. A caret at the block's head would be the same
    /// gesture saying less.
    ///
    /// The other half of the map, `revealSource`, selects without taking the
    /// keyboard: that one is something to look at, this one is somewhere to
    /// type.
    private func goToSource(_ source: NSRange) {
        guard let note = currentNote else { return }
        let length = note.storage.length
        let location = max(0, min(source.location, length))
        let end = max(location, min(NSMaxRange(source), length))
        // A jump is a move, not a typing session: vim comes back to normal
        // mode for it, the way `gg` or a mark would leave you.
        if preferences.vimMode, vimEngine.mode != .normal { vimEngine.enterNormalMode() }
        textView.setSelectedRange(NSRange(location: location, length: end - location))
        // Vim's rule that the caret may not sit past the last character is
        // about a caret; a selection it would quietly throw away.
        if preferences.vimMode, end == location { vimEngine.clampCaret() }
        revealInEditor(textView.selectedRange())
        // The pane is read, not typed in.
        focusEditor()
    }

    /// The content pointed at a piece of the source without asking for the
    /// keyboard — a row of a dump clicked, which stands over the `INSERT`
    /// that wrote it; a row of a tree, which stands over its member; a column
    /// of a grid picked out of many rows, which is one range per row and not
    /// the block of lines it sits beside. Every range is *selected* and
    /// brought into view, and that is all: the pane keeps the focus, so the
    /// arrows go on walking it.
    ///
    /// A reveal is something to look at; a jump — `goToSource`, the render's
    /// own click — is somewhere to type. That is the whole difference between
    /// them, and it is why this one selects and that one does not: a
    /// selection handed to the keyboard would be replaced by the next
    /// keystroke.
    ///
    /// Split only, since the editor is only on screen there.
    private func revealSource(_ sources: [NSRange]) {
        guard let note = currentNote, installedPreviewMode == .split, !sources.isEmpty
        else { return }
        let length = note.storage.length
        let clamped = sources.map { source -> NSRange in
            let location = max(0, min(source.location, length))
            let end = max(location, min(NSMaxRange(source), length))
            return NSRange(location: location, length: end - location)
        }
        if preferences.vimMode, vimEngine.mode != .normal { vimEngine.enterNormalMode() }
        if let only = clamped.first, clamped.count == 1 {
            textView.setSelectedRange(only)
        } else {
            textView.selectedRanges = clamped.map { NSValue(range: $0) }
        }
        // Vim's rule that the caret may not sit past the last character is
        // about a caret; a selection it would quietly throw away. Several
        // ranges are never a caret, so this only ever asks about the one.
        if preferences.vimMode, clamped.count == 1, clamped[0].length == 0 {
            vimEngine.clampCaret()
        }
        guard let span = SQLGridView.span(of: clamped) else { return }
        revealInEditor(span)
    }

    /// A heading chosen from the ⇧⌘J switcher's `@` list (Todo 9): the caret
    /// goes to its line start and is scrolled into view, and — in split or
    /// reading, where there is a render to be pointing at — the pane is
    /// walked to that block by hand, the same `highlightBlock(containingSource:)`
    /// a caret move already drives in split. Reading has no editor on screen,
    /// so the keyboard is left where it was rather than jumping to it.
    private func goToHeading(_ heading: MarkdownHeadings.Heading) {
        guard let note = currentNote else { return }
        let location = max(0, min(heading.location, note.storage.length))
        if preferences.vimMode, vimEngine.mode != .normal { vimEngine.enterNormalMode() }
        textView.setSelectedRange(NSRange(location: location, length: 0))
        if preferences.vimMode { vimEngine.clampCaret() }
        revealInEditor(textView.selectedRange())
        if installedPreviewMode == .split || installedPreviewMode == .reading {
            previewColumn.current.highlightBlock(containingSource: location)
        }
        if installedPreviewMode != .reading { focusEditor() }
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
              textView.textContainer != nil,
              let length = currentNote?.storage.length, length > 0
        else { return nil }
        // A jump is usually to somewhere that has never been on screen, so it
        // has no rectangle yet — but only its own neighbourhood needs laying
        // out to find one; a 100 MB note must not pay for the rest of itself
        // just to answer where one line sits.
        let character = min(max(0, range.location), length - 1)
        let characterRange = NSRange(location: character, length: 1)
        layoutManager.ensureLayout(forCharacterRange: characterRange)
        let glyph = layoutManager.glyphRange(
            forCharacterRange: characterRange, actualCharacterRange: nil
        ).location
        var rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        rect.origin.y += textView.textContainerOrigin.y
        rect.origin.x += textView.textContainerOrigin.x
        return rect
    }
}

// MARK: - Images and book contents: chips and sidebar

extension MainWindowController {

    var isImageSidebarVisible: Bool { sidebarIsVisible }

    /// Which of the three lists the column holds for the tab in front. By the
    /// tab's kind and by nothing else: a book is read by its contents and a
    /// document by its pages whether or not either has anything in it, and a
    /// book with no contents at all is what the quiet hint is for.
    enum SidebarList { case gallery, contents, pages }

    var sidebarList: SidebarList {
        switch currentNote?.kind {
        case .epub: .contents
        case .pdf: .pages
        default: .gallery
        }
    }

    /// Whether the column is a book's table of contents rather than a note's
    /// pictures.
    var sidebarShowsContents: Bool { sidebarList == .contents }

    /// Whether it is a document's pages.
    var sidebarShowsPages: Bool { sidebarList == .pages }

    /// What the View item is named after: what the column is listing. The
    /// item keeps the long names — the titles in the column itself are one
    /// word each. English keys; the menu is what puts them through `L10n`.
    var sidebarListTitle: String {
        switch sidebarList {
        case .gallery: "Image Gallery"
        case .contents: "Table of Contents"
        case .pages: "Page List"
        }
    }

    /// The two lists a tab that is read puts up — for the tests, which have
    /// no other way to ask the column which of its three it is holding.
    var contentsSidebarView: ContentsSidebarView { contentsSidebar }
    var pageListSidebarView: PageListSidebarView { pageListSidebar }

    /// ⌘B. Pins the sidebar open or shut, overriding the follow-the-tab
    /// default for the rest of the session. One pin for both lists: hiding
    /// the gallery on a note hides the contents on a book too, since it is
    /// the same column being told to go away.
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
    ///
    /// A book or a PDF has no chips to renumber; what its column shows is the
    /// document's own contents, brought up and put away by the same pin and
    /// the same follow-the-tab default.
    fileprivate func refreshImages(force: Bool = false) {
        sidebarWorkItem?.cancel()
        sidebarWorkItem = nil
        if let note = currentNote, sidebarList != .gallery {
            refreshReadingList(of: note, force: force)
            return
        }
        guard let storage = currentNote?.storage else { return }

        let font = preferences.font()
        var assetIDs: [String] = []
        var resized: [NSRange] = []
        var number = 1

        storage.forEachAttachmentRun { value, range, _ in
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

        applySidebarVisibility(itemCount: assetIDs.count)
        if sidebarIsVisible {
            showSidebarList(.gallery)
            imageSidebar.setAssetIDs(assetIDs, force: force)
            updateSidebarHighlight()
        }
    }

    /// Which of the three views in the column is the one on screen.
    private func showSidebarList(_ list: SidebarList) {
        imageSidebar.isHidden = list != .gallery
        contentsSidebar.isHidden = list != .contents
        pageListSidebar.isHidden = list != .pages
    }

    /// The tab in front, listed: a book's contents, a document's pages. What
    /// either of them is remains the content view's business, and nothing
    /// here asks — one hands over `ContentsEntry` lines, the other a page
    /// source, and the count of whichever it is says whether the column comes
    /// up at all.
    ///
    /// Every document has pages, so a PDF always brings the column up; only a
    /// book with no contents lists nothing and stays away until ⌘B pins it
    /// open on the hint.
    private func refreshReadingList(of note: Note, force: Bool) {
        let content = previewColumn.content(for: note)
        switch sidebarList {
        case .gallery:
            return
        case .contents:
            let entries = content.contentsEntries
            applySidebarVisibility(itemCount: entries.count)
            guard sidebarIsVisible else { return }
            showSidebarList(.contents)
            contentsSidebar.setEntries(entries, force: force)
        case .pages:
            let pages = content.pageList
            applySidebarVisibility(itemCount: pages?.pageCount ?? 0)
            guard sidebarIsVisible else { return }
            showSidebarList(.pages)
            pageListSidebar.setPages(pages, force: force)
        }
        updateContentsSelection()
    }

    /// Rings the line naming what is on screen. Called when the contents are
    /// listed and again on every move the content reports, so a chapter
    /// turned and a page scrolled past both walk the list.
    fileprivate func updateContentsSelection() {
        guard sidebarIsVisible, let note = currentNote else { return }
        let content = previewColumn.content(for: note)
        switch sidebarList {
        case .gallery: break
        case .contents: contentsSidebar.setSelectedLine(content.currentContentsLine)
        case .pages: pageListSidebar.setSelectedPage(content.pageList?.currentPageIndex)
        }
    }

    private func applySidebarVisibility(itemCount: Int) {
        let shouldShow: Bool
        switch sidebarVisibility {
        case .followsNote: shouldShow = itemCount > 0
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
        storage.forEachAttachmentRun { value, range, _ in
            if value is NotaImageAttachment { locations.append(range.location) }
        }
        return locations
    }

    /// Rings the sidebar item for the chip the caret is touching, or for any
    /// chip inside the selection.
    fileprivate func updateSidebarHighlight() {
        // A book's or a document's column is rung by what is on screen, not
        // by a caret in text there is none of.
        guard sidebarIsVisible, sidebarList == .gallery else { return }
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

extension MainWindowController: ContentsSidebarViewDelegate {
    /// Clicking a line goes where it points — a chapter and its `#anchor`, a
    /// destination on a page — and the ring goes with it. The keyboard stays
    /// where it was: these tabs are read, and there is no editor to go back
    /// to.
    func contentsSidebar(_ sidebar: ContentsSidebarView, didChooseLine line: Int) {
        guard let note = currentNote, sidebarShowsContents else { return }
        previewColumn.content(for: note).goToContentsLine(line)
        updateContentsSelection()
    }
}

extension MainWindowController: PageListSidebarViewDelegate {
    /// Clicking a page card goes to the top of that page, and the ring goes
    /// with it. The keyboard stays where it was, the way a chosen line leaves
    /// it: a document is read, and there is no editor to go back to.
    func pageListSidebar(_ sidebar: PageListSidebarView, didChoosePage page: Int) {
        guard let note = currentNote, sidebarShowsPages else { return }
        previewColumn.content(for: note).pageList?.goToPage(page)
        updateContentsSelection()
    }
}

// MARK: - Search across tabs

extension MainWindowController {

    /// ⇧⌘F. The ⇧⌘J panel again, in its search mode: the query runs over every
    /// open tab and each row is a hit. A note is searched by its text, a
    /// document by its pages and a book by its chapters — each tab says what
    /// it has (SPEC Done 37). The per-tab find bar (⌘F) is untouched.
    func beginSearchAllNotes() {
        guard let window else { return }
        showWindow(nil)
        tabPicker.showSearch(
            notes: notes.map(\.searchSource),
            symbolNames: notes.map { $0.iconSymbolName },
            bookmarkedTabs: bookmarkedTabs,
            over: window
        )
    }

    /// Choosing a hit: switch to its tab, and take the reader to where the hit
    /// lives — the match selected in the editor, on the document's page, or in
    /// the chapter of the book it is written in.
    fileprivate func reveal(_ match: NoteSearchMatch, query: String) {
        selectTab(at: match.tabIndex)

        // Hand the query to the find bar so ⌘G carries on from here. Done
        // before the reveal, since a viewer's own find session is started with
        // the same query and reads the board on the way past.
        let findBoard = NSPasteboard(name: .find)
        findBoard.clearContents()
        findBoard.setString(query, forType: .string)

        switch match.location {
        case .text(let range):
            focusEditor()
            guard let storage = textView.textStorage else { return }
            let location = min(range.location, storage.length)
            let length = min(range.length, storage.length - location)
            textView.setSelectedRange(NSRange(location: location, length: length))
            textView.scrollRangeToVisible(textView.selectedRange())
        case .pdf(let page, let range):
            guard let note = currentNote else { return }
            (previewColumn.content(for: note) as? PDFPreviewView)?
                .reveal(page: page, range: range, query: query)
        case .book(let chapter, _):
            guard let note = currentNote else { return }
            (previewColumn.content(for: note) as? EPUBPreviewView)?
                .reveal(chapter: chapter, query: query)
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

    func tabBarDidToggleFrontTabBookmark(_ bar: TabBarView) {
        toggleBookmarkForCurrentTab()
    }

    func tabBarDidRequestBookmarks(_ bar: TabBarView) {
        showBookmarksPicker()
    }

    func tabBarDidRequestSettings(_ bar: TabBarView) {
        openSettings(nil)
    }

    func tabBar(_ bar: TabBarView, didToggleBookmarkAt index: Int) {
        toggleBookmark(at: index)
    }

    func tabBar(_ bar: TabBarView, didRequestRevealAt index: Int) {
        revealInFinder(at: index)
    }

    func tabBar(_ bar: TabBarView, didDropFiles urls: [URL]) {
        openDroppedFiles(urls)
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
        // strip starts wherever it currently does — after the traffic
        // lights, or at the 12pt inset if they are hidden or a left sidebar
        // has their slot — the torn tab is the first one in it, and the
        // strip's middle is the height it is grabbed at.
        let size = window.frame.size
        let pointerOffset = NSPoint(
            x: currentTabStripLeadingInset + grabOffset.x,
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
        // First, so that everything below which works the corner out again —
        // `refreshTabs` on the way to dirty, for one — finds a re-parse
        // already on its way and leaves it to the debounce.
        scheduleFormatSlotRefresh()
        if !note.isDirty {
            note.isDirty = true
            refreshTabs()
        }
        rememberSelection(note)
        updateStatus(countsDebounced: true)
        // The matches have moved with the edit. ⌘F's bar owns the bands for
        // as long as it is up, so it is the one that lays them on again;
        // vim gets them back the moment the bar closes.
        if findSession.isVisible {
            scheduleFindRefresh(for: note)
        } else {
            vimEngine.refreshSearchHighlights()
        }
        scheduleImageRefresh()
        // And what the text now reads as, once the typing stops.
        scheduleFormatOffer()
        // The blocks have moved under the pane; nothing is lit again until it
        // has been rendered afresh.
        previewColumn.content(for: note).invalidateBlocks()
        schedulePreviewRefresh()
        scheduleSave()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // The editor is between two notes; see `installCurrentNote`.
        guard !isSwappingNote else { return }
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
    /// A pill's fields get a field editor of Nota's own, so a Find menu item
    /// sent while the reader is typing in one reaches the pill rather than
    /// AppKit's own text finder. Every other field in the window keeps the
    /// window's — answering `nil` is how that is asked for.
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard let field = client as? PillTextField else { return nil }
        pillFieldEditor.owner = field.owner
        return pillFieldEditor
    }

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
