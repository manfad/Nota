import AppKit

struct TabBarItem {
    var title: String
    var isDirty: Bool
    /// The file behind this tab has changed on disk while the tab had edits
    /// of its own. Drawn as a hairline ring round the unsaved dot — the dot
    /// still says "unsaved", the ring says "and the file has moved".
    var hasExternalChange: Bool = false
    /// The leading icon's name, from the file's kind (`FileKindIcon`).
    /// Defaulted so a strip test that only cares about titles need not say.
    var symbolName: String = FileKindIcon.untitledSymbolName
    /// The file behind this tab is bookmarked (SPEC Todo 13). Drawn by
    /// filling the leading icon in — the same kind, solid — rather than by
    /// putting a second mark on its corner.
    var isBookmarked: Bool = false
    /// There is a file on disk behind this tab, so "Reveal in Finder" has
    /// somewhere to go. An untitled note has none and the item is greyed.
    var hasFile: Bool = false
}

protocol TabBarViewDelegate: AnyObject {
    func tabBar(_ bar: TabBarView, didSelect index: Int)
    func tabBar(_ bar: TabBarView, didRequestCloseAt index: Int)
    func tabBarDidRequestNewTab(_ bar: TabBarView)
    func tabBar(_ bar: TabBarView, didMove index: Int, to newIndex: Int)

    /// The dragged tab has left the strip far enough to stop being part of
    /// this window: the strip has given up its own reorder, and the tab
    /// belongs to a window of its own from here. `grabOffset` is where
    /// inside the tab the pointer took hold of it, so the tab can be placed
    /// under the pointer in the window it lands in.
    func tabBar(_ bar: TabBarView, tearOff index: Int, grabOffset: NSPoint, screenPoint: NSPoint)
    /// Every drag after a tear-off. The strip has nothing left to move; it
    /// only keeps the gesture flowing to whoever owns the torn tab.
    func tabBarDragMoved(_ bar: TabBarView, to screenPoint: NSPoint)
    /// The release (`committed`) or Esc (`false`) that ends a torn-off drag.
    func tabBarDragEnded(_ bar: TabBarView, committed: Bool, at screenPoint: NSPoint)

    /// The Bookmark button at the trailing edge of the strip: ⌘D, by
    /// another door — the tab in front bookmarked, or unbookmarked.
    func tabBarDidToggleFrontTabBookmark(_ bar: TabBarView)
    /// The Bookmarks button beside it: the picker, in bookmarks mode.
    func tabBarDidRequestBookmarks(_ bar: TabBarView)
    /// "Bookmark" / "Remove Bookmark" in a tab's context menu.
    func tabBar(_ bar: TabBarView, didToggleBookmarkAt index: Int)
    /// "Reveal in Finder" in a tab's context menu; only offered on a tab
    /// with a file.
    func tabBar(_ bar: TabBarView, didRequestRevealAt index: Int)
    /// The gear past the bookmark button: Settings, ⌘, by another door.
    func tabBarDidRequestSettings(_ bar: TabBarView)

    /// Files dragged in from the Finder and let go on the strip. The strip is
    /// a tab target, so each one opens as a tab of its own — pictures
    /// included, which is the whole difference from a drop into the text.
    func tabBar(_ bar: TabBarView, didDropFiles urls: [URL])
}

/// Tear-off, bookmarks and dropped files are the parts of the strip a
/// delegate may ignore — a test recorder that only cares about selection
/// still compiles.
extension TabBarViewDelegate {
    func tabBar(_ bar: TabBarView, tearOff index: Int, grabOffset: NSPoint, screenPoint: NSPoint) {}
    func tabBarDragMoved(_ bar: TabBarView, to screenPoint: NSPoint) {}
    func tabBarDragEnded(_ bar: TabBarView, committed: Bool, at screenPoint: NSPoint) {}
    func tabBarDidToggleFrontTabBookmark(_ bar: TabBarView) {}
    func tabBarDidRequestBookmarks(_ bar: TabBarView) {}
    func tabBar(_ bar: TabBarView, didToggleBookmarkAt index: Int) {}
    func tabBar(_ bar: TabBarView, didRequestRevealAt index: Int) {}
    func tabBarDidRequestSettings(_ bar: TabBarView) {}
    func tabBar(_ bar: TabBarView, didDropFiles urls: [URL]) {}
}

extension NSPasteboard {
    /// Every file a drag is carrying, in the order it holds them and with
    /// nothing left out. What each one becomes is the drop target's business,
    /// not the file's: the text keeps pictures for itself as chips (that is
    /// `NotaTextView.openableFiles`), the tab targets take the lot.
    var draggedFileURLs: [URL] {
        guard types?.contains(.fileURL) == true else { return [] }
        return readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
    }
}

/// The strip of tabs that sits in the title bar next to the traffic lights.
/// Tabs share one width that shrinks as tabs are added, the way a browser's
/// do; the strip never scrolls. `TabStripLayout` owns that arithmetic, this
/// view only puts the frames where it says and runs the drag.
final class TabBarView: NSView {
    weak var delegate: TabBarViewDelegate?

    /// Tabs are clipped to the strip rather than spilling over the window.
    override var clipsToBounds: Bool {
        get { true }
        set { _ = newValue }
    }

    static let height: CGFloat = 34

    private static let tabHeight: CGFloat = 24
    private static let spacing = TabStripLayout.spacing
    private static let newTabButtonSize = TabStripLayout.plusSize

    /// Drag-to-reorder tuning: how long a slide/settle animation takes, and
    /// — only when tabs are hidden — the hot zone at either end that reveals
    /// one more slot, and how often. The move-vs-click threshold itself lives
    /// on `TabItemView`, the only place that needs it; how a lifted tab looks
    /// is its own `isLifted`.
    private static let dragAnimationDuration: TimeInterval = 0.12
    /// Keeps a tab from flickering between two slots when the pointer rests
    /// directly on their boundary.
    private static let dragSlotHysteresis: CGFloat = 4
    private static let dragRevealEdge: CGFloat = 24
    private static let dragRevealInterval: TimeInterval = 0.25
    /// How far out of the strip the pointer goes before the tab stops being
    /// this window's — Chromium's `kTearawayDistance` in spirit.
    private static let tearOffDistance: CGFloat = 40
    /// The insertion caret a strip shows while a torn-off tab hovers it.
    private static let dropCaretWidth: CGFloat = 2

    /// The hairline drawn in the gap between two plain tabs.
    private static let separatorHeight: CGFloat = 12

    private var items: [TabBarItem] = []
    private var selectedIndex = 0
    private var itemViews: [TabItemView] = []

    /// `TabStripLayout.showsTabIcons` has changed: every tab lays its title
    /// out again, from behind the icon or from the tab's own edge.
    func tabIconsDidChange() {
        for view in itemViews {
            view.needsLayout = true
            view.needsDisplay = true
        }
    }

    private let newTabButton = NewTabButton()
    private let bookmarkToggleButton = BookmarkToggleButton()
    private let bookmarksButton = BookmarksButton()
    private let settingsButton = SettingsButton()

    /// Where the sliding window starts when the tabs no longer fit even at
    /// their floor. Fed back into the next layout so the window stays put
    /// while the selection moves inside it.
    private var firstVisibleIndex = 0

    /// The tab under the pointer, if any: separators are not drawn beside it.
    private var hoveredIndex: Int?

    /// Chromium's `in_tab_close_`: after a ✕ the tabs that remain keep the
    /// widths they had and close up the gap, so a run of closes leaves each
    /// next ✕ under the pointer. Dropped when the pointer leaves the strip.
    /// ⌘W never comes through the ✕, so it relayouts straight away.
    private struct CloseFreeze {
        var widths: [CGFloat]
        var firstVisibleIndex: Int
        var plusX: CGFloat
    }

    private var closeFreeze: CloseFreeze?
    private var hoverArea: NSTrackingArea?

    /// The strip normally draws on the transparent title bar and brings no
    /// background of its own. Auto-hide lifts it off the layout and lays it
    /// over the document instead, where it has to be opaque — a fill and a
    /// hairline along the edge it now sits on.
    var drawsOpaqueBackground = false {
        didSet {
            guard drawsOpaqueBackground != oldValue else { return }
            needsDisplay = true
        }
    }

    /// The pointer arriving at and leaving the strip, for an owner that has
    /// to know: an auto-hiding strip stays for as long as the pointer is on
    /// it and slides away behind it.
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?

    /// A gesture the pointer owns is underway in the strip — a reorder drag,
    /// a tab torn off it, or files from the Finder held over it. An
    /// auto-hiding strip must not slide out from under one.
    var isDraggingForOverlay: Bool {
        dragSession != nil || isTornOff || isFileDragOverStrip
    }

    /// A Finder drag is hovering the strip, waiting to be let go. It is not
    /// this view's own gesture — AppKit runs it — so nothing else here knows
    /// about it, and the overlay would otherwise slide away mid-drop.
    private var isFileDragOverStrip = false

    /// A tab's context menu is up. The pointer is free to walk off the strip
    /// while it is, and the strip has to still be there when the menu closes.
    private(set) var isShowingContextMenuForOverlay = false

    /// State for a tab currently being dragged along the strip. `nil` when
    /// nothing is being dragged.
    private struct DragSession {
        /// Index of the dragged tab in `items`/`itemViews` — never changes
        /// during the drag; only its visual slot does.
        let originalIndex: Int
        /// Where `originalIndex` currently sits in `visualOrder`.
        var currentSlot: Int
        /// Display order as the drag has rearranged it so far, as a
        /// permutation of `items` indices. Never written back to `items` —
        /// the delegate is told the final slot and owns the real reorder.
        var visualOrder: [Int]
        /// Widths snapshot at drag start, indexed like `items`.
        let widths: [CGFloat]
        /// How many leading slots the window has hidden, and the leading x
        /// that follows from it. Edge-reveal moves both.
        var revealedSlots: Int
        var originX: CGFloat
        /// The + stays where it was for the length of the drag.
        let plusX: CGFloat
        let startPointerX: CGFloat
        let startViewX: CGFloat
        var lastPointerX: CGFloat
        /// Where inside the tab the pointer took hold of it. The tab must
        /// stay under the pointer when it lands in a window of its own.
        let grabOffset: NSPoint
    }

    private var dragSession: DragSession?
    private var dragRevealTimer: Timer?
    private var dragEscMonitor: Any?
    /// True from the moment a drag leaves the strip until it is released.
    /// The strip reorders nothing any more; it only carries the rest of the
    /// gesture to the delegate, which owns the window the tab is now in.
    private var isTornOff = false
    /// The gap a tab released now would drop into, when this strip is the
    /// one under another window's torn-off tab.
    private var dropCaretSlot: Int?

    /// The strip never lets AppKit move the window on its own: with the
    /// automatic region on, a press on a tab dragged the window *and* the
    /// tab at once (the tab's refusal was not honoured). Dragging the empty
    /// strip still moves the window — `mouseDown` starts that drag itself.
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        newTabButton.target = self
        newTabButton.action = #selector(requestNewTab)
        addSubview(newTabButton)
        bookmarkToggleButton.target = self
        bookmarkToggleButton.action = #selector(toggleFrontTabBookmark)
        addSubview(bookmarkToggleButton)
        bookmarksButton.target = self
        bookmarksButton.action = #selector(requestBookmarks)
        addSubview(bookmarksButton)
        settingsButton.target = self
        settingsButton.action = #selector(requestSettings)
        addSubview(settingsButton)
        // The strip is a tab target: files let go on it open as tabs. The
        // reorder gesture cannot collide with this one — that is a mouse
        // tracking loop, and an external drag never sends mouse events.
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Double-clicking the empty strip behaves like double-clicking a title bar,
    /// honouring System Settings ▸ Desktop & Dock ▸ "Double-click a window's title bar to".
    override func mouseDown(with event: NSEvent) {
        guard let window else { return super.mouseDown(with: event) }
        guard event.clickCount == 2 else { return window.performDrag(with: event) }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }

    // MARK: - Dropping files from outside

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isFileDragOverStrip = !sender.draggingPasteboard.draggedFileURLs.isEmpty
        return isFileDragOverStrip ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isFileDragOverStrip ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isFileDragOverStrip = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isFileDragOverStrip = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isFileDragOverStrip = false
        let urls = sender.draggingPasteboard.draggedFileURLs
        guard !urls.isEmpty else { return false }
        delegate?.tabBar(self, didDropFiles: urls)
        return true
    }

    func setItems(_ items: [TabBarItem], selectedIndex: Int) {
        // A tab closing (⌘W) or opening mid-drag changes the item count out
        // from under `dragSession.visualOrder`, which is a permutation of
        // indices sized for the old count — stale indices into it would be
        // a crash waiting to happen, so the drag is simply abandoned first.
        if dragSession != nil, items.count != itemViews.count {
            cancelDrag()
        }
        self.items = items
        self.selectedIndex = selectedIndex
        rebuild()
    }

    // MARK: - Dropping a torn-off tab

    /// Shows where a tab released now would go in: a caret in the gap
    /// itself, the way a browser marks the insertion point. `nil` clears it.
    func showDropCaret(at slot: Int?) {
        guard dropCaretSlot != slot else { return }
        dropCaretSlot = slot
        needsDisplay = true
    }

    /// This point on screen inside the strip, in the strip's own
    /// coordinates — `nil` when the pointer is somewhere else entirely.
    func barPoint(forScreenPoint point: NSPoint) -> NSPoint? {
        guard let window else { return nil }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        return bounds.contains(local) ? local : nil
    }

    /// The slot a tab released here would take. The visible tabs' midpoints
    /// are the boundaries, so the caret follows the pointer tab by tab.
    func dropSlot(at pointer: NSPoint) -> Int {
        var slot = itemViews.firstIndex { !$0.isHidden } ?? 0
        for (index, view) in itemViews.enumerated() where !view.isHidden {
            guard pointer.x >= view.frame.midX else { break }
            slot = index + 1
        }
        return slot
    }

    /// Where the caret is drawn for `slot`: the middle of the gap before
    /// that tab, or after the last one.
    private func dropCaretX(for slot: Int) -> CGFloat {
        if itemViews.indices.contains(slot), !itemViews[slot].isHidden {
            return itemViews[slot].frame.minX - Self.spacing / 2
        }
        return (itemViews.last { !$0.isHidden }?.frame.maxX ?? 0) + Self.spacing / 2
    }

    // MARK: - Test hooks

    /// Test hook: whether the selected tab is on-screen, unhidden, and
    /// entirely within the strip (never under the + button).
    internal func isSelectedTabFullyVisible() -> Bool {
        guard itemViews.indices.contains(selectedIndex) else { return false }
        let view = itemViews[selectedIndex]
        guard !view.isHidden else { return false }
        return view.frame.minX >= 0 && view.frame.maxX <= newTabButton.frame.minX + 0.01
    }

    /// Test hook: the titles in their current display order.
    internal var titlesForTesting: [String] { items.map(\.title) }

    /// What each tab is saying about itself, for the tests: unsaved edits,
    /// and whether the file behind it has changed on disk under them.
    internal var marksForTesting: [(isDirty: Bool, hasExternalChange: Bool)] {
        items.map { ($0.isDirty, $0.hasExternalChange) }
    }

    /// Test hook: whether the tab at `index` shows its leading file icon.
    internal func hasFileIconForTesting(at index: Int) -> Bool {
        guard itemViews.indices.contains(index) else { return false }
        return itemViews[index].iconImageForTesting != nil
    }

    /// Test hook: the SF Symbol each tab's leading icon draws — the file
    /// kind the strip thinks that tab is.
    internal var iconSymbolNamesForTesting: [String] { itemViews.map(\.iconSymbolName) }

    /// Test hook: the actual image each tab's leading icon is drawing — so a
    /// test can tell this app's own art (a template image) apart from an SF
    /// Symbol without launching the app.
    internal var iconImagesForTesting: [NSImage?] { itemViews.map(\.iconImageForTesting) }

    /// Test hook: the view for the tab at `index`, for hit-testing.
    internal func tabViewForTesting(at index: Int) -> NSView? {
        itemViews.indices.contains(index) ? itemViews[index] : nil
    }

    /// Test hook: every tab's frame, hidden ones included.
    internal var tabFramesForTesting: [NSRect] { itemViews.map(\.frame) }

    /// Test hook: which tabs are on screen.
    internal var hiddenTabsForTesting: [Bool] { itemViews.map(\.isHidden) }

    /// Test hook: where the + sits.
    internal var newTabButtonFrameForTesting: NSRect { newTabButton.frame }

    /// Test hook: where the Bookmark toggle sits.
    internal var bookmarkToggleButtonFrameForTesting: NSRect { bookmarkToggleButton.frame }

    /// Test hook: where the Bookmarks button sits.
    internal var bookmarksButtonFrameForTesting: NSRect { bookmarksButton.frame }

    /// Test hook: where the Settings gear sits.
    internal var settingsButtonFrameForTesting: NSRect { settingsButton.frame }

    /// Test hook: which of the three trailing buttons Settings has hidden.
    internal var trailingButtonsHiddenForTesting:
        (bookmarkToggle: Bool, bookmark: Bool, settings: Bool) {
        (bookmarkToggleButton.isHidden, bookmarksButton.isHidden, settingsButton.isHidden)
    }

    /// Test hook: what the Bookmark toggle is saying about the front tab —
    /// the symbol it is drawing, whether it can be pressed, and its tip.
    internal var bookmarkToggleStateForTesting:
        (symbol: String?, isEnabled: Bool, toolTip: String?) {
        (bookmarkToggleButton.symbolNameForTesting, bookmarkToggleButton.isEnabled,
         bookmarkToggleButton.toolTip)
    }

    /// Test hook: which tabs are drawing their kind's icon filled — which
    /// is what says they are bookmarked.
    internal var filledIconsForTesting: [Bool] { itemViews.map(\.drawsFilledIcon) }

    /// Test hook: how much of the hover wash each tab is wearing — 0 at rest
    /// and on the selected tab, which never takes it.
    internal var hoverFillAlphasForTesting: [CGFloat] { itemViews.map(\.hoverFillAlphaForTesting) }

    /// Test hook: the same for the + button, which fades its wash in over the
    /// same 0.12s the tabs do.
    internal var newTabButtonHoverAlphaForTesting: CGFloat { newTabButton.hoverFillAlphaForTesting }

    /// Test hook: the context menu a right-click on the tab at `index` puts
    /// up — there is no window server here to raise one.
    internal func contextMenuForTesting(at index: Int) -> NSMenu? {
        guard itemViews.indices.contains(index) else { return nil }
        return contextMenu(for: itemViews[index])
    }

    /// Test hook: clicks the Bookmark toggle at the trailing edge. A button
    /// Settings has switched off, or one greyed because the front tab has no
    /// file, does nothing — exactly as the pointer would find it.
    internal func pressBookmarkToggleButtonForTesting() {
        guard !bookmarkToggleButton.isHidden, bookmarkToggleButton.isEnabled else { return }
        toggleFrontTabBookmark()
    }

    /// Test hook: clicks the Bookmarks button at the trailing edge.
    internal func pressBookmarksButtonForTesting() { requestBookmarks() }

    /// Test hook: clicks the Settings gear.
    internal func pressSettingsButtonForTesting() { requestSettings() }

    /// Test hook: closes the tab at `index` the way its ✕ does — ⌘W arrives
    /// through `setItems` instead and never freezes the widths.
    internal func closeViaButtonForTesting(at index: Int) {
        guard itemViews.indices.contains(index) else { return }
        close(itemViews[index])
    }

    /// Test hook: whether a ✕ close is still holding the widths still.
    internal var isFrozenAfterCloseForTesting: Bool { closeFreeze != nil }

    /// Test hook: starts a drag on `index`, as if the pointer had just
    /// crossed the threshold there, without going through mouse events.
    internal func beginDragForTesting(index: Int) {
        guard itemViews.indices.contains(index) else { return }
        let view = itemViews[index]
        beginDrag(for: view, pointer: NSPoint(x: view.frame.midX, y: bounds.midY))
    }

    /// Test hook: the dragged tab's current x, or `nil` when nothing is
    /// being dragged.
    internal var draggedTabXForTesting: CGFloat? {
        guard let session = dragSession else { return nil }
        return itemViews[session.originalIndex].frame.minX
    }

    /// Test hook: advances the active drag in the same coordinate space as
    /// `TabItemView`'s real mouse events.
    internal func updateDragForTesting(pointerX: CGFloat,
                                       pointerY: CGFloat? = nil,
                                       screenPoint: NSPoint = .zero) {
        let index = dragSession?.originalIndex ?? 0
        guard itemViews.indices.contains(index) else { return }
        guard dragSession != nil || isTornOff else { return }
        updateDrag(
            for: itemViews[index],
            pointer: NSPoint(x: pointerX, y: pointerY ?? bounds.midY),
            screenPoint: screenPoint
        )
    }

    /// Test hook: releases (or, with `committed` false, abandons) the drag
    /// the way a mouse-up or Esc inside the tracking loop would.
    internal func endDragForTesting(committed: Bool, at screenPoint: NSPoint = .zero) {
        let index = dragSession?.originalIndex ?? 0
        guard itemViews.indices.contains(index) else { return }
        endDrag(for: itemViews[index], committed: committed, screenPoint: screenPoint)
    }

    /// Test hook: the gap the insertion caret is sitting in, if any.
    internal var dropCaretSlotForTesting: Int? { dropCaretSlot }

    /// Test hook: whether the strip has handed its tab to another window.
    internal var isTornOffForTesting: Bool { isTornOff }

    /// Test hook: the slot the dragged tab would occupy if dropped now.
    internal var draggedTabSlotForTesting: Int? { dragSession?.currentSlot }

    /// Test hook: performs the delegate call a completed drag would make —
    /// `index` moved to `newIndex` — without going through mouse events or
    /// the slide/settle animations. The delegate owns the actual reorder
    /// (see `MainWindowController.moveTab`); this only exercises that the
    /// strip reports moves correctly.
    internal func moveTabForTesting(from index: Int, to newIndex: Int) {
        guard itemViews.indices.contains(index), itemViews.indices.contains(newIndex),
              index != newIndex else { return }
        delegate?.tabBar(self, didMove: index, to: newIndex)
    }

    // MARK: - Items

    private func rebuild() {
        while itemViews.count > items.count {
            itemViews.removeLast().removeFromSuperview()
        }
        while itemViews.count < items.count {
            let view = TabItemView()
            view.onSelect = { [weak self] tab in self?.select(tab) }
            view.onClose = { [weak self] tab in self?.close(tab) }
            view.onHoverChange = { [weak self] tab, hovering in self?.hoverChanged(tab, hovering) }
            view.onDragStart = { [weak self] tab, grab in self?.beginDrag(for: tab, pointer: grab) }
            view.onDragMove = { [weak self] tab, pointer, screen in
                self?.updateDrag(for: tab, pointer: pointer, screenPoint: screen)
            }
            view.onDragEnd = { [weak self] tab, committed, screen in
                self?.endDrag(for: tab, committed: committed, screenPoint: screen)
            }
            view.onContextMenu = { [weak self] tab in self?.contextMenu(for: tab) }
            addSubview(view, positioned: .below, relativeTo: newTabButton)
            itemViews.append(view)
        }
        for (index, item) in items.enumerated() {
            itemViews[index].configure(item, isSelected: index == selectedIndex)
        }
        needsLayout = true
    }

    @objc private func requestNewTab() {
        delegate?.tabBarDidRequestNewTab(self)
    }

    @objc private func toggleFrontTabBookmark() {
        delegate?.tabBarDidToggleFrontTabBookmark(self)
    }

    @objc private func requestBookmarks() {
        delegate?.tabBarDidRequestBookmarks(self)
    }

    @objc private func requestSettings() {
        delegate?.tabBarDidRequestSettings(self)
    }

    /// The tab's context menu (right-click, ctrl-click): bookmark it, show
    /// its file in the Finder, or close it. Built here rather than on the tab view so the strip's own
    /// indices — the only ones the delegate knows — are what the items carry.
    private func contextMenu(for view: TabItemView) -> NSMenu? {
        guard let index = itemViews.firstIndex(of: view), items.indices.contains(index) else {
            return nil
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let bookmark = NSMenuItem(
            title: items[index].isBookmarked ? "Remove Bookmark" : "Bookmark",
            action: #selector(toggleBookmarkFromMenu(_:)), keyEquivalent: ""
        )
        bookmark.target = self
        bookmark.tag = index
        menu.addItem(bookmark)
        let reveal = NSMenuItem(
            title: "Reveal in Finder", action: #selector(revealFromMenu(_:)), keyEquivalent: ""
        )
        reveal.target = self
        reveal.tag = index
        reveal.isEnabled = items[index].hasFile
        menu.addItem(reveal)
        menu.addItem(.separator())
        let close = NSMenuItem(
            title: "Close Tab", action: #selector(closeFromMenu(_:)), keyEquivalent: ""
        )
        close.target = self
        close.tag = index
        menu.addItem(close)
        menu.delegate = self
        return menu
    }

    @objc private func toggleBookmarkFromMenu(_ sender: NSMenuItem) {
        delegate?.tabBar(self, didToggleBookmarkAt: sender.tag)
    }

    @objc private func revealFromMenu(_ sender: NSMenuItem) {
        delegate?.tabBar(self, didRequestRevealAt: sender.tag)
    }

    @objc private func closeFromMenu(_ sender: NSMenuItem) {
        guard itemViews.indices.contains(sender.tag) else { return }
        close(itemViews[sender.tag])
    }

    private func select(_ view: TabItemView) {
        guard let index = itemViews.firstIndex(of: view) else { return }
        delegate?.tabBar(self, didSelect: index)
    }

    private func close(_ view: TabItemView) {
        guard let index = itemViews.firstIndex(of: view) else { return }
        freezeWidths(closing: index)
        delegate?.tabBar(self, didRequestCloseAt: index)
    }

    private func hoverChanged(_ view: TabItemView, _ hovering: Bool) {
        guard let index = itemViews.firstIndex(of: view) else { return }
        if hovering {
            hoveredIndex = index
        } else if hoveredIndex == index {
            hoveredIndex = nil
        }
        needsDisplay = true
    }

    // MARK: - Layout

    /// Room the tabs themselves may use: the strip minus the + and its gap.
    private var tabsWidth: CGFloat {
        TabStripLayout.tabsWidth(bounds.width)
    }

    /// The plan the strip is on right now: the frozen one while a ✕ close is
    /// holding the widths still, otherwise a fresh one.
    private func currentLayout() -> TabStripLayout {
        if let freeze = closeFreeze, freeze.widths.count == items.count {
            return TabStripLayout(
                widths: freeze.widths,
                firstVisibleIndex: freeze.firstVisibleIndex,
                plusX: freeze.plusX,
                viewportWidth: bounds.width
            )
        }
        // A freeze whose count no longer matches (the close was cancelled by
        // a save prompt, or a tab was opened meanwhile) is stale.
        closeFreeze = nil
        return TabStripLayout(
            count: items.count,
            selectedIndex: selectedIndex,
            viewportWidth: bounds.width,
            previousFirstVisibleIndex: firstVisibleIndex
        )
    }

    /// Snapshots the strip minus the tab that is about to go, so the tabs
    /// that remain keep their width and simply close the gap — the next ✕
    /// then lands under the pointer that just clicked one.
    private func freezeWidths(closing index: Int) {
        let plan = currentLayout()
        guard plan.widths.indices.contains(index), plan.widths.count > 1 else { return }
        var widths = plan.widths
        widths.remove(at: index)
        closeFreeze = CloseFreeze(
            widths: widths,
            firstVisibleIndex: min(plan.firstVisibleIndex, widths.count - 1),
            plusX: plan.plusX
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    /// The pointer leaving the strip is what ends a run of ✕ closes: the
    /// widths are free to settle again.
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerExited?()
        hoveredIndex = nil
        guard closeFreeze != nil else { return }
        closeFreeze = nil
        needsLayout = true
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerEntered?()
    }

    override func layout() {
        super.layout()

        // A drag owns the strip's positions while it is underway: the
        // dragged tab rides the pointer and its siblings sit at their
        // `visualOrder` slot. A layout arriving mid-drag — a resize, a
        // dirty-dot refresh from `setItems`, an autosave tick — must not
        // fight that by resetting every frame back to `items`' plain order,
        // which would yank the dragged tab out from under the pointer.
        if let session = dragSession {
            layoutDuringDrag(session)
            return
        }

        let plan = currentLayout()
        firstVisibleIndex = plan.firstVisibleIndex
        place(plan)
        needsDisplay = true
    }

    private func place(_ plan: TabStripLayout) {
        placeBookmarksButton()
        let plusSize = Self.newTabButtonSize
        newTabButton.frame = NSRect(
            x: plan.plusX,
            y: (bounds.height - plusSize) / 2,
            width: plusSize,
            height: plusSize
        )

        let y = (bounds.height - Self.tabHeight) / 2
        for (index, view) in itemViews.enumerated() {
            guard plan.widths.indices.contains(index) else {
                view.isHidden = true
                continue
            }
            view.frame = NSRect(
                x: plan.xs[index], y: y, width: plan.widths[index], height: Self.tabHeight
            )
            // Outside the sliding window means off the strip: not drawn, and
            // not clickable either.
            view.isHidden = !plan.visibleRange.contains(index)
        }
    }

    /// The three trailing buttons are pinned at the trailing edge and never
    /// move with the tabs, so they are placed the same way whatever else the
    /// strip is doing — a drag included.
    private func placeBookmarksButton() {
        func place(_ button: StripButton, size: CGFloat, x: CGFloat) {
            button.frame = NSRect(x: x, y: (bounds.height - size) / 2, width: size, height: size)
        }
        place(bookmarkToggleButton, size: TabStripLayout.bookmarkToggleSlot,
              x: TabStripLayout.bookmarkToggleX(bounds.width))
        place(bookmarksButton, size: TabStripLayout.bookmarkSlot,
              x: TabStripLayout.bookmarkX(bounds.width))
        place(settingsButton, size: TabStripLayout.settingsSlot,
              x: TabStripLayout.settingsX(bounds.width))
        // A button Settings has switched off is not drawn and not clickable;
        // the layout has already given its slot back to the tabs.
        bookmarkToggleButton.isHidden = !TabStripLayout.controls.bookmarkToggle
        bookmarksButton.isHidden = !TabStripLayout.controls.bookmark
        settingsButton.isHidden = !TabStripLayout.controls.settings
    }

    /// What the Bookmark toggle says about the tab in front: the filled
    /// bookmark once it is one, the outline while it is not, and greyed out
    /// on a note that has no file to bookmark. The window calls this
    /// wherever it refreshes the strip, so a tab switch and somebody else's
    /// window bookmarking the same file both land here.
    func setFrontTabBookmark(canBookmark: Bool, isBookmarked: Bool) {
        bookmarkToggleButton.setState(canBookmark: canBookmark, isBookmarked: isBookmarked)
        // The button beside it says nothing about the tab, but its words are
        // translated and the language can change under an open window — so
        // they are written again on the same beat rather than only at birth.
        bookmarksButton.refreshLabel()
    }

    /// Brave draws a hairline only between two plain tabs — never beside the
    /// selected one, never beside the one under the pointer. It lives in the
    /// gap, which belongs to the strip rather than to either tab.
    override func draw(_ dirtyRect: NSRect) {
        // Overlaying the document rather than sitting in the title bar: the
        // strip brings its own ground and a hairline to stand on.
        // The editor's own ground, not the window's: the strip normally sits
        // over the document with nothing painted behind it, and the
        // revealed one must look exactly the same — no hairline either.
        if drawsOpaqueBackground {
            NSColor.textBackgroundColor.setFill()
            NSBezierPath(rect: bounds).fill()
        }
        super.draw(dirtyRect)

        if let slot = dropCaretSlot {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(rect: NSRect(
                x: dropCaretX(for: slot) - Self.dropCaretWidth / 2,
                y: (bounds.height - Self.tabHeight) / 2,
                width: Self.dropCaretWidth,
                height: Self.tabHeight
            )).fill()
        }

        guard itemViews.count > 1 else { return }
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        let y = (bounds.height - Self.separatorHeight) / 2
        for index in 0..<(itemViews.count - 1) {
            let left = itemViews[index], right = itemViews[index + 1]
            guard !left.isHidden, !right.isHidden else { continue }
            guard index != selectedIndex, index + 1 != selectedIndex else { continue }
            guard index != hoveredIndex, index + 1 != hoveredIndex else { continue }
            let center = (left.frame.maxX + right.frame.minX) / 2
            NSBezierPath(
                rect: NSRect(x: center - 0.5, y: y, width: 1, height: Self.separatorHeight)
            ).fill()
        }
    }

    // MARK: - Drag to reorder

    private func beginDrag(for view: TabItemView, pointer: NSPoint) {
        guard dragSession == nil, !isTornOff, let index = itemViews.firstIndex(of: view) else { return }
        let plan = currentLayout()
        guard plan.widths.count == itemViews.count else { return }
        dragSession = DragSession(
            originalIndex: index,
            currentSlot: index,
            visualOrder: Array(itemViews.indices),
            widths: plan.widths,
            revealedSlots: plan.firstVisibleIndex,
            originX: plan.xs.first ?? 0,
            plusX: plan.plusX,
            startPointerX: pointer.x,
            startViewX: view.frame.minX,
            lastPointerX: pointer.x,
            grabOffset: NSPoint(x: pointer.x - view.frame.minX, y: pointer.y - view.frame.minY)
        )
        // Above every sibling while it rides the pointer, solid so nothing it
        // passes over shows through, with a shadow under it to read as lifted.
        addSubview(view, positioned: .above, relativeTo: nil)
        view.isLifted = true
        startEscMonitor()
    }

    /// `pointer` is `nil` once the dragged tab has left the strip — the note
    /// has gone to another window and its view went with it, so there is no
    /// strip left to place it against. Only the screen point matters then.
    private func updateDrag(for view: TabItemView, pointer: NSPoint?, screenPoint: NSPoint) {
        // Past the tear-off the strip is only a courier: the tab is a window
        // now, and coming back over the strip does not dock it again —
        // Chromium does not re-dock either, the window simply follows.
        if isTornOff {
            delegate?.tabBarDragMoved(self, to: screenPoint)
            return
        }
        guard let pointer, let session = dragSession else { return }
        if hasLeftTheStrip(pointer) {
            tearOff(session, screenPoint: screenPoint)
            return
        }
        dragSession?.lastPointerX = pointer.x
        updateDragPositions(pointerX: pointer.x)
        updateEdgeReveal(pointerX: pointer.x)
    }

    /// Far enough above or below the strip, or off either side of the
    /// window: the pointer is no longer arranging this window's tabs.
    private func hasLeftTheStrip(_ pointer: NSPoint) -> Bool {
        if pointer.y < -Self.tearOffDistance || pointer.y > bounds.height + Self.tearOffDistance {
            return true
        }
        guard let window else { return false }
        let inWindow = convert(pointer, to: nil)
        return inWindow.x < 0 || inWindow.x > window.frame.width
    }

    /// Hands the tab over. The strip drops its own reorder outright rather
    /// than cancelling it: the dragged tab is about to leave `items`, so
    /// sliding it home would only animate a tab on its way out.
    private func tearOff(_ session: DragSession, screenPoint: NSPoint) {
        stopEdgeReveal()
        stopEscMonitor()
        dragSession = nil
        isTornOff = true
        itemViews[session.originalIndex].isLifted = false
        restoreSubviewOrdering()
        needsLayout = true
        delegate?.tabBar(self, tearOff: session.originalIndex,
                         grabOffset: session.grabOffset, screenPoint: screenPoint)
    }

    /// Moves the tab one-to-one with the pointer, then snaps the gap to the
    /// nearest insertion slot. This is how browser tab strips behave: the
    /// possible resting places are fixed, and their halfway points are the
    /// reorder boundaries. It stays predictable with mixed tab widths and
    /// also lets a quick gesture skip several tabs in one event.
    private func updateDragPositions(pointerX: CGFloat) {
        guard var session = dragSession, itemViews.indices.contains(session.originalIndex) else { return }
        let widths = session.widths
        let draggedWidth = widths[session.originalIndex]
        let proposedX = session.startViewX + (pointerX - session.startPointerX)
        let clampedX = min(max(0, proposedX), max(0, tabsWidth - draggedWidth))

        let draggedView = itemViews[session.originalIndex]
        var draggedFrame = draggedView.frame
        draggedFrame.origin.x = clampedX
        draggedView.frame = draggedFrame

        let draggedCenter = clampedX + draggedWidth / 2
        let siblings = session.visualOrder.filter { $0 != session.originalIndex }

        // The centre the dragged tab would have in each possible resting
        // slot. Adjacent centres define a natural halfway reorder boundary.
        var candidateCenters: [CGFloat] = []
        var x = session.originX
        for slot in 0...siblings.count {
            candidateCenters.append(x + draggedWidth / 2)
            if slot < siblings.count {
                x += widths[siblings[slot]] + Self.spacing
            }
        }

        let nearestSlot = candidateCenters.indices.min {
            abs(draggedCenter - candidateCenters[$0])
                < abs(draggedCenter - candidateCenters[$1])
        } ?? session.currentSlot
        let currentDistance = abs(draggedCenter - candidateCenters[session.currentSlot])
        let nearestDistance = abs(draggedCenter - candidateCenters[nearestSlot])

        // A few points of hysteresis make the gap stay put under a resting
        // pointer instead of rapidly swapping back and forth on a boundary.
        if nearestSlot != session.currentSlot,
           nearestDistance + Self.dragSlotHysteresis < currentDistance {
            var newOrder = siblings
            newOrder.insert(session.originalIndex, at: nearestSlot)
            session.currentSlot = nearestSlot
            session.visualOrder = newOrder

            var siblingX = session.originX
            for originalIndex in newOrder {
                if originalIndex != session.originalIndex {
                    animateSibling(itemViews[originalIndex], to: siblingX)
                }
                siblingX += widths[originalIndex] + Self.spacing
            }
        }

        dragSession = session
    }

    /// Total the tabs want, spacing included.
    private func totalWidth(_ session: DragSession) -> CGFloat {
        session.widths.reduce(0, +) + Self.spacing * CGFloat(max(0, session.widths.count - 1))
    }

    /// Only a strip with hidden tabs has an edge behaviour: holding the
    /// pointer at either end brings one more slot in, so a tab can be
    /// dropped onto a slot the window is not showing. A strip where
    /// everything fits has nothing to reveal and stays still.
    private func updateEdgeReveal(pointerX: CGFloat) {
        guard let session = dragSession, totalWidth(session) > tabsWidth else {
            return stopEdgeReveal()
        }
        let direction: Int
        if pointerX < Self.dragRevealEdge {
            direction = -1
        } else if pointerX > tabsWidth - Self.dragRevealEdge {
            direction = 1
        } else {
            direction = 0
        }
        guard direction != 0 else { return stopEdgeReveal() }
        guard dragRevealTimer == nil else { return }
        let timer = Timer(timeInterval: Self.dragRevealInterval, repeats: true) { [weak self] timer in
            guard let self, self.dragRevealTimer === timer, self.dragSession != nil else {
                return timer.invalidate()
            }
            self.revealOneSlot(direction: direction)
        }
        RunLoop.main.add(timer, forMode: .common)
        dragRevealTimer = timer
    }

    private func stopEdgeReveal() {
        dragRevealTimer?.invalidate()
        dragRevealTimer = nil
    }

    /// Slides the window by one slot, if there is anything to slide towards.
    private func revealOneSlot(direction: Int) {
        guard var session = dragSession else { return }
        if direction < 0 {
            guard session.revealedSlots > 0 else { return }
            session.revealedSlots -= 1
        } else {
            guard session.revealedSlots < session.widths.count - 1,
                  session.originX + totalWidth(session) > tabsWidth else { return }
            session.revealedSlots += 1
        }
        var origin: CGFloat = 0
        for slot in 0..<session.revealedSlots {
            origin -= session.widths[session.visualOrder[slot]] + Self.spacing
        }
        session.originX = origin
        dragSession = session
        layoutDuringDrag(session)
        updateDragPositions(pointerX: session.lastPointerX)
    }

    /// Snaps every non-dragged tab to its current slot — used when the window
    /// slides under the pointer, which is a jump rather than a slide, so it
    /// is not animated.
    private func repositionSiblingsDuringDrag(session: DragSession) {
        var x = session.originX
        for slot in session.visualOrder {
            if slot != session.originalIndex {
                var frame = itemViews[slot].frame
                frame.origin.x = x
                itemViews[slot].frame = frame
            }
            x += session.widths[slot] + Self.spacing
        }
    }

    /// The drag-aware half of `layout()`: positions come from the session
    /// rather than `items`' plain order — the dragged tab is left exactly
    /// where the drag last put it (and is never hidden), while its siblings
    /// go to their current `visualOrder` slot.
    private func layoutDuringDrag(_ session: DragSession) {
        placeBookmarksButton()
        let plusSize = Self.newTabButtonSize
        newTabButton.frame = NSRect(
            x: session.plusX,
            y: (bounds.height - plusSize) / 2,
            width: plusSize,
            height: plusSize
        )

        repositionSiblingsDuringDrag(session: session)

        var x = session.originX
        for slot in session.visualOrder {
            let width = session.widths[slot]
            if slot == session.originalIndex {
                itemViews[slot].isHidden = false
            } else {
                itemViews[slot].isHidden = x + width < 0 || x >= tabsWidth || x + width > tabsWidth
            }
            x += width + Self.spacing
        }
    }

    private func endDrag(for view: TabItemView, committed: Bool, screenPoint: NSPoint) {
        if isTornOff {
            isTornOff = false
            showDropCaret(at: nil)
            delegate?.tabBarDragEnded(self, committed: committed, at: screenPoint)
            return
        }
        guard let session = dragSession else { return }
        stopEdgeReveal()
        stopEscMonitor()
        dragSession = nil

        if committed, session.currentSlot != session.originalIndex {
            let targetX = slotX(session.currentSlot, order: session.visualOrder, widths: session.widths)
                + session.originX
            settle(view, to: targetX) { [weak self] in
                guard let self else { return }
                view.isLifted = false
                self.restoreSubviewOrdering()
                self.delegate?.tabBar(self, didMove: session.originalIndex, to: session.currentSlot)
            }
        } else {
            // Nothing moved, or Esc cancelled it: every tab that slid
            // during the drag animates back to where it started.
            let identityOrder = Array(itemViews.indices)
            for index in identityOrder {
                let targetX = slotX(index, order: identityOrder, widths: session.widths)
                    + session.originX
                settle(itemViews[index], to: targetX, completion: index == session.originalIndex ? {
                    view.isLifted = false
                } : nil)
            }
            restoreSubviewOrdering()
        }
    }

    private func cancelDrag() {
        guard let session = dragSession else { return }
        endDrag(for: itemViews[session.originalIndex], committed: false, screenPoint: .zero)
    }

    /// Sum of the widths (plus spacing) of every tab before `slot` in
    /// `order` — the slot's offset from the first one.
    private func slotX(_ slot: Int, order: [Int], widths: [CGFloat]) -> CGFloat {
        var x: CGFloat = 0
        for i in 0..<slot { x += widths[order[i]] + Self.spacing }
        return x
    }

    /// Animates a sibling sliding into the gap the dragged tab left —
    /// short, and skipped under Reduce Motion.
    private func animateSibling(_ view: NSView, to x: CGFloat) {
        settle(view, to: x, completion: nil)
    }

    /// A slide is aimed at where the drag thought the tab belonged, and an
    /// animator keeps setting the frame until it lands — so a layout that ran
    /// meanwhile (a tab opened or closed mid-drag, the selection settling) is
    /// overwritten, and the tab comes to rest half over its neighbour. Once
    /// the strip is no longer being dragged, every landing hands the frames
    /// back to `layout()`, which is the only thing that knows the real slots.
    private func settle(_ view: NSView, to x: CGFloat, completion: (() -> Void)?) {
        var frame = view.frame
        frame.origin.x = x
        let landed = { [weak self] in
            completion?()
            guard let self, self.dragSession == nil, !self.isTornOff else { return }
            self.needsLayout = true
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            view.frame = frame
            landed()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.dragAnimationDuration
            view.animator().frame = frame
        }, completionHandler: landed)
    }

    /// Restores the strip's normal subview stacking (tabs in index order,
    /// all below the +) after a drag has brought one tab to the front.
    private func restoreSubviewOrdering() {
        for view in itemViews {
            addSubview(view, positioned: .below, relativeTo: newTabButton)
        }
    }

    /// Covers a drag that did not come from `TabItemView.mouseDown` — the
    /// test hook, in practice. A real drag runs inside that view's tracking
    /// loop, where local monitors are never called, so the loop handles Esc
    /// itself.
    private func startEscMonitor() {
        stopEscMonitor()
        dragEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.dragSession != nil else { return event }
            guard event.keyCode == 53 else { return event } // Esc
            self.cancelDrag()
            return nil
        }
    }

    private func stopEscMonitor() {
        if let dragEscMonitor { NSEvent.removeMonitor(dragEscMonitor) }
        dragEscMonitor = nil
    }
}

/// A tab's context menu, only so the strip knows while one is up: an
/// auto-hiding strip has to still be there when the menu closes, however far
/// the pointer wandered to reach an item.
extension TabBarView: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        isShowingContextMenuForOverlay = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isShowingContextMenuForOverlay = false
        onPointerExited?()
    }
}

/// The greys the strip paints itself in. There is no colour in it, so how
/// much `labelColor` a shape carries is the only thing that says what state
/// it is in, and the ladder has to be read at a glance: the selected tab is
/// the strongest mark in the strip, the wash under the pointer a clear step
/// lighter than it — near enough and two tabs read as selected at once — and
/// a press one step darker again than the thing it is pressing. Dark mode
/// takes a touch more of each: a white wash over a dark strip carries less
/// than a black one over a light strip.
enum StripWash {
    /// The rounded fill behind the selected tab.
    static func selected(for view: NSView) -> NSColor { grey(view, light: 0.10, dark: 0.12) }
    /// The pointer resting on an unselected tab, or on a strip button.
    static func hover(for view: NSView) -> NSColor { grey(view, light: 0.035, dark: 0.05) }
    /// A strip button held down.
    static func pressed(for view: NSView) -> NSColor { grey(view, light: 0.09, dark: 0.115) }
    /// The disc behind the ✕, which is a small shape and needs more grey
    /// than a tab-wide wash to read as one.
    static func closeDisc(for view: NSView) -> NSColor { grey(view, light: 0.10, dark: 0.13) }
    /// That disc while the ✕ is held down.
    static func closeDiscPressed(for view: NSView) -> NSColor { grey(view, light: 0.18, dark: 0.22) }

    private static func grey(_ view: NSView, light: CGFloat, dark: CGFloat) -> NSColor {
        let isDark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.labelColor.withAlphaComponent(isDark ? dark : light)
    }
}

/// The wash a tab or a strip button wears under the pointer. A view of its
/// own rather than another pass in `draw(_:)` so its alpha can be animated:
/// the wash then arrives and leaves with the dot→✕ cross-fade beside it
/// instead of snapping on while that fades. Transparent to the mouse, and
/// told when it is being pressed — a press is a darker grey, which alpha
/// alone cannot say.
private final class HoverFillView: NSView {
    var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        (isPressed ? StripWash.pressed(for: self) : StripWash.hover(for: self)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

/// Trailing control on the tab strip. Same density as a tab (24pt), not an
/// iOS-sized hit target; a quiet template symbol that lights up under the
/// pointer, and — like the tabs and the ✕ — a press it must keep for itself
/// rather than letting AppKit turn into a window drag.
class StripButton: NSButton {
    /// The same 0.12s the tabs fade their slot over: the two are the same
    /// gesture arriving at two neighbours, and must not run at two speeds.
    private static let hoverFadeDuration: TimeInterval = 0.12

    private let hoverFill = HoverFillView()
    private var hoverArea: NSTrackingArea?
    private var isHovered = false {
        didSet { if isHovered != oldValue { updateHoverFill(animated: true) } }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// A button greyed while the pointer is still on it drops the wash with
    /// it: the light is what says a click would land, and none would.
    override var isEnabled: Bool {
        didSet { if !isEnabled { isHovered = false } }
    }

    /// The symbol this button is drawing. `NSImage` hands back the picture
    /// and not the name it was made from, so a button whose symbol changes
    /// writes it down as it sets it.
    private(set) var symbolNameForTesting: String?

    init(symbolName: String, name: String, toolTip: String) {
        super.init(frame: .zero)
        symbolNameForTesting = symbolName
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: name)?
            .withSymbolConfiguration(config)
        finishInit(name: name, toolTip: toolTip)
    }

    /// A button drawing this app's own template art — an `NSImage` built
    /// from embedded SVG (see `BookmarksButton`'s book) — rather than asking
    /// AppKit for an SF Symbol by name. There is no symbol name to read the
    /// picture back from, so the caller hands one down for
    /// `symbolNameForTesting` to report.
    init(templateImage: NSImage, testingName: String, name: String, toolTip: String) {
        super.init(frame: .zero)
        symbolNameForTesting = testingName
        image = templateImage
        finishInit(name: name, toolTip: toolTip)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func finishInit(name: String, toolTip: String) {
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        self.toolTip = toolTip
        setAccessibilityLabel(name)
        setAccessibilityRole(.button)
        hoverFill.alphaValue = 0
        addSubview(hoverFill)
    }

    /// Swaps the picture without touching anything else about the button —
    /// the template flag stays on, so `contentTintColor` keeps colouring it.
    func setSymbol(_ name: String) {
        guard name != symbolNameForTesting else { return }
        symbolNameForTesting = name
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityLabel())?
            .withSymbolConfiguration(config)
    }

    override func layout() {
        super.layout()
        hoverFill.frame = bounds
    }

    /// Test hook: how much of the hover wash this button is wearing.
    internal var hoverFillAlphaForTesting: CGFloat { hoverFill.alphaValue }

    private func updateHoverFill(animated: Bool) {
        hoverFill.isPressed = isHighlighted
        let target: CGFloat = (isHovered || isHighlighted) ? 1 : 0
        guard animated else {
            hoverFill.alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.hoverFadeDuration
            hoverFill.animator().alphaValue = target
        }
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        // A press is an answer to a click and lands at once; only the
        // release, which may take the wash away with it, is worth a fade.
        updateHoverFill(animated: !flag)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // A greyed button takes no click, so it lights up for nobody.
        isHovered = isEnabled
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
    }
}

/// The + that rides after the last tab and pins at the trailing edge.
final class NewTabButton: StripButton {
    init() {
        super.init(symbolName: "plus", name: "New Tab", toolTip: "New Tab  ⌘T")
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The Bookmark button, first of the three in the strip's top-right corner:
/// ⌘D by another door — it bookmarks the tab in front, and unbookmarks it
/// again. The symbol is the answer as much as the offer: an outline while the
/// tab is not bookmarked, filled once it is, which is the same pair the badge
/// on the tab's own icon uses. A note with no file has nothing to bookmark,
/// and the button is greyed rather than quietly doing nothing.
final class BookmarkToggleButton: StripButton {
    init() {
        super.init(symbolName: "bookmark", name: "Bookmark", toolTip: "Bookmark")
        setState(canBookmark: false, isBookmarked: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setState(canBookmark: Bool, isBookmarked: Bool) {
        setSymbol(isBookmarked ? "bookmark.fill" : "bookmark")
        isEnabled = canBookmark
        // A greyed button keeps the shape of the offer and loses its weight:
        // `secondaryLabelColor` is the idle colour, one step quieter again
        // while there is nothing to press. AppKit does not dim a bordered-off
        // button that was given a tint of its own, so it is said here.
        contentTintColor = canBookmark ? .secondaryLabelColor : .tertiaryLabelColor
        let key = Preferences.shared.combo(for: .bookmarkTab).displayName
        let name = L10n.text(isBookmarked ? "Remove Bookmark" : "Bookmark")
        setAccessibilityLabel(name)
        toolTip = name + "  " + key
    }
}

/// The Bookmark dialog button beside it (SPEC Todo 13): the ⇧⌘J picker,
/// opened straight into its bookmarks list. A closed book with its own
/// bookmark ribbon rather than a second loose ribbon — the button beside it
/// is the ribbon, and two of them in a row said nothing about which was
/// which. This app's own art (`bookSVG` below) rather than the SF Symbol
/// `book.closed`, so the ribbon reads at strip size; drawn as a template
/// image exactly like `FileKindIcon`'s badges, so `contentTintColor` still
/// colours it.
final class BookmarksButton: StripButton {
    init() {
        super.init(
            templateImage: Self.bookImage,
            testingName: "nota.book.bookmark", name: "Bookmark dialog", toolTip: ""
        )
        refreshLabel()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func refreshLabel() {
        let name = L10n.text("Bookmark dialog")
        setAccessibilityLabel(name)
        toolTip = name + "  " + Preferences.shared.combo(for: .showBookmarks).displayName
    }

    /// A 64×64 square badge, so — unlike `FileKindIcon`'s 3:2 badges — its
    /// image is square too. Measured offscreen (a bounding box of the
    /// non-transparent pixels, light and dark): `book.closed` and
    /// `gearshape` at the strip's 11pt medium both draw 12.125pt of ink
    /// high. This art's own padding sits it lower in its box, so it takes a
    /// 14.5pt image to stand the same 12pt or so of ink — 16.6pt, this
    /// badge's height if it stood as tall as an SF Symbol's full em, ran a
    /// visible notch taller than the gear beside it. The source art's
    /// 4-unit stroke is thickened to 5: at 4 the lines read noticeably
    /// thinner than the gear's, 5 sits right beside it in weight, and 6
    /// starts to look bolder than its neighbours.
    private static let bookImage: NSImage = {
        let data = BookmarksButton.bookSVG.data(using: .utf8)!
        let image = NSImage(data: data)!
        image.isTemplate = true
        image.size = NSSize(width: 14.5, height: 14.5)
        return image
    }()

    private static let bookSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64" fill="none">
      <g stroke="currentColor" stroke-width="5" stroke-linecap="round" stroke-linejoin="round">
        <path d="M18 10H44C47.314 10 50 12.686 50 16V38C50 41.314 47.314 44 44 44H18C14.686 44 12 46.686 12 50V16C12 12.686 14.686 10 18 10Z"/>
        <path d="M18 44C14.686 44 12 46.686 12 50S14.686 56 18 56H49"/>
        <path d="M46 44C41 47 41 53 46 56"/>
        <path d="M20 11V43"/>
      </g>
      <path d="M29 10H41V30C41 30.84 40.03 31.31 39.37 30.79L35 27.3L30.63 30.79C29.97 31.31 29 30.84 29 30V10Z" fill="currentColor"/>
    </svg>
    """
}

/// The Settings gear in the strip's top-right corner, past the bookmark: the
/// same window ⌘, opens.
final class SettingsButton: StripButton {
    init() {
        super.init(symbolName: "gearshape", name: "Settings", toolTip: "Settings  ⌘,")
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

// MARK: - One tab

/// A tab in the Safari/Xcode shape: a soft rounded fill when selected, the
/// title, and a single 16pt slot at the trailing edge.
///
/// The slot is always reserved down to `minActiveWidth`, so a tab never
/// changes width when it is selected or hovered. It holds two stacked layers
/// — the unsaved dot and the close button — which cross-fade as the pointer
/// arrives and leaves. Narrower than that there is no room for either: the
/// dot moves onto the icon and the ✕ is gone, as it is in Chromium.
private final class TabItemView: NSView {
    var onSelect: ((TabItemView) -> Void)?
    var onClose: ((TabItemView) -> Void)?
    /// Fired when the pointer arrives or leaves, so the strip knows which
    /// gaps must not show a separator.
    var onHoverChange: ((TabItemView, Bool) -> Void)?
    /// Fired once when the press turns into a drag, with the *original*
    /// mouse-down x in the tab bar's coordinates. Keeping that grab point
    /// prevents the tab from lagging behind the pointer by the activation
    /// threshold. It arrives from inside `mouseDown`'s tracking loop, after
    /// the tab has already been selected.
    var onDragStart: ((TabItemView, NSPoint) -> Void)?
    /// Fired on every subsequent drag, with the pointer in the bar's
    /// coordinates and on screen. The screen point is what survives the tab
    /// leaving the window: after a tear-off the events belong to the new
    /// window, and the bar's own coordinates mean nothing to it any more —
    /// the tab view itself is usually out of the strip by then, which is
    /// what the bar point being optional says.
    var onDragMove: ((TabItemView, NSPoint?, NSPoint) -> Void)?
    /// Fired once a drag was underway and has finished: `committed` is
    /// `true` on mouse-up, `false` when Esc abandoned it mid-gesture, with
    /// the pointer on screen at that moment.
    var onDragEnd: ((TabItemView, Bool, NSPoint) -> Void)?
    /// The menu a right-click or ctrl-click on this tab puts up. The strip
    /// builds it: only the strip knows this tab's index.
    var onContextMenu: ((TabItemView) -> NSMenu?)?

    private static let font = NSFont.systemFont(ofSize: 12)
    private static let horizontalPadding: CGFloat = 10
    private static let slotSize: CGFloat = 16
    private static let slotTrailingPadding: CGFloat = 6
    private static let titleSlotGap: CGFloat = 4
    private static let crossFadeDuration: TimeInterval = 0.12
    private static let dragThreshold: CGFloat = 3
    /// The icon slot: the badge art is three units wide to two high, so the
    /// slot is too — 24 × 16, where a square 16 used to be.
    private static let iconWidth: CGFloat = 24
    private static let iconHeight: CGFloat = 16
    private static let iconTitleGap: CGFloat = 5
    /// The title is clipped rather than ellipsized, with the last few points
    /// faded out; below the shorter figure there is no room worth drawing in.
    private static let titleFadeWidth: CGFloat = 12
    private static let minimumTitleWidth: CGFloat = 12
    /// The unsaved dot when it has to sit on the icon instead of in the slot.
    private static let compactDotDiameter: CGFloat = 5
    /// The point size every kind's icon is drawn at.
    private static let iconPointSize: CGFloat = 11

    private var title = ""
    private var isDirty = false
    private var hasExternalChange = false
    private var isBookmarked = false
    private var isSelected = false
    private var isHovered = false
    private var isHoveringClose = false
    private var isPressingClose = false
    private var dragTrackingStart: NSPoint?
    private var isDraggingTab = false
    /// The last pointer position on screen this gesture saw. Esc arrives as
    /// a key event, which has no useful location of its own.
    private var lastDragScreenPoint: NSPoint = .zero

    private let dotView = DirtyDotView()
    private let closeButton = TabCloseButton()
    private let iconView = TabIconView()
    private let hoverFillView = HoverFillView()
    private var hoverArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    /// Riding the pointer in a drag: a soft shadow under the pill, the way a
    /// lifted tab reads in Safari. The strip leaves 5pt above and below a
    /// tab, so the shadow is kept inside that.
    var isLifted = false {
        didSet {
            guard isLifted != oldValue else { return }
            shadow = isLifted ? Self.liftShadow : nil
        }
    }

    private static let liftShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 4
        return shadow
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // First in, so every other piece of the tab sits over the wash.
        hoverFillView.alphaValue = 0
        addSubview(hoverFillView)

        setIcon(named: FileKindIcon.untitledSymbolName, filled: false)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        dotView.alphaValue = 0
        addSubview(dotView)

        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?
            .withSymbolConfiguration(config)
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.alphaValue = 0
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.onHoverChange = { [weak self] hovering in
            guard let self, self.isHoveringClose != hovering else { return }
            self.isHoveringClose = hovering
            self.needsDisplay = true
        }
        closeButton.onHighlightChange = { [weak self] pressed in
            guard let self, self.isPressingClose != pressed else { return }
            self.isPressingClose = pressed
            self.needsDisplay = true
        }
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Test hook: the icon image currently shown, so a test can confirm
    /// every tab gets one without launching the app.
    internal var iconImageForTesting: NSImage? { iconView.image }

    /// Test hook: which SF Symbol the leading icon is drawing, so a test can
    /// check a tab's icon follows its file kind.
    internal private(set) var iconSymbolName = ""
    /// Which of the two drawings of that kind is up, so `setIcon` knows a
    /// bookmark toggle is a change even though the name has not moved.
    private var isIconFilled = false

    /// Test hook: whether this tab is drawing the filled art — which is what
    /// says it is bookmarked.
    internal var drawsFilledIcon: Bool { isBookmarked }

    private func setIcon(named symbolName: String, filled: Bool) {
        guard symbolName != iconSymbolName || filled != isIconFilled else { return }
        iconSymbolName = symbolName
        isIconFilled = filled
        iconView.image = FileKindIcon.image(
            named: symbolName, pointSize: Self.iconPointSize, filled: filled
        )
    }

    func configure(_ item: TabBarItem, isSelected: Bool) {
        title = item.title
        // A bookmarked tab draws the same kind of icon solid; that is the
        // whole mark, so nothing is drawn on the corner.
        setIcon(named: item.symbolName, filled: item.isBookmarked)
        isDirty = item.isDirty
        hasExternalChange = item.hasExternalChange
        isBookmarked = item.isBookmarked
        dotView.showsRing = item.hasExternalChange
        self.isSelected = isSelected
        toolTip = item.title
        updateSlot(animated: false)
        needsDisplay = true
        needsLayout = true
    }

    /// Too narrow for the trailing slot: no ✕ even on hover, and the unsaved
    /// dot rides on the icon instead.
    private var isCompact: Bool { bounds.width < TabStripLayout.minActiveWidth }

    private var slotRect: NSRect {
        NSRect(
            x: bounds.maxX - Self.slotTrailingPadding - Self.slotSize,
            y: (bounds.height - Self.slotSize) / 2,
            width: Self.slotSize,
            height: Self.slotSize
        )
    }

    private var iconRect: NSRect {
        NSRect(
            x: Self.horizontalPadding,
            y: (bounds.height - Self.iconHeight) / 2,
            width: Self.iconWidth,
            height: Self.iconHeight
        )
    }

    /// The room left for the title once the icon, and the slot when there is
    /// one, have taken theirs.
    private var titleRect: NSRect {
        let x = TabStripLayout.showsTabIcons
            ? Self.horizontalPadding + Self.iconWidth + Self.iconTitleGap
            : Self.horizontalPadding
        let trailing = isCompact
            ? bounds.maxX - Self.horizontalPadding
            : slotRect.minX - Self.titleSlotGap
        return NSRect(x: x, y: 0, width: max(0, trailing - x), height: bounds.height)
    }

    override func layout() {
        super.layout()
        hoverFillView.frame = bounds
        iconView.frame = iconRect
        iconView.isHidden = !TabStripLayout.showsTabIcons
        dotView.frame = slotRect
        closeButton.frame = slotRect
        let compact = isCompact
        dotView.isHidden = compact
        closeButton.isHidden = compact
    }

    /// Hovering swaps the dot for the ✕ and lays the wash under the tab; a
    /// clean, unhovered tab shows neither. All three move together over the
    /// same 0.12s — one arrival of the pointer, not a wash that snaps on
    /// while the slot beside it is still fading.
    ///
    /// The selected tab takes no wash: its own fill is the strongest mark in
    /// the strip and the pointer has nothing to add to it.
    private func updateSlot(animated: Bool) {
        let dotAlpha: CGFloat = (isDirty && !isHovered) ? 1 : 0
        let closeAlpha: CGFloat = isHovered ? 1 : 0
        let hoverAlpha: CGFloat = (isHovered && !isSelected) ? 1 : 0
        guard animated else {
            dotView.alphaValue = dotAlpha
            closeButton.alphaValue = closeAlpha
            hoverFillView.alphaValue = hoverAlpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.crossFadeDuration
            dotView.animator().alphaValue = dotAlpha
            closeButton.animator().alphaValue = closeAlpha
            hoverFillView.animator().alphaValue = hoverAlpha
        }
    }

    /// Test hook: how much of the hover wash this tab is wearing, so a test
    /// can tell a hovered tab from the selected one without a screenshot.
    internal var hoverFillAlphaForTesting: CGFloat { hoverFillView.alphaValue }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateSlot(animated: true)
        needsDisplay = true
        onHoverChange?(self, true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isHoveringClose = false
        updateSlot(animated: true)
        needsDisplay = true
        onHoverChange?(self, false)
    }

    /// The strip sits in the title-bar region, so a press while another app
    /// is frontmost is an activation click. Views refuse those by default,
    /// which leaves the press to the frame view, and a drag from there moves
    /// the window; the tab only gets the *next* press. Accepting first mouse
    /// delivers that first press here, so a tab in a background window can be
    /// selected and dragged in one go, as in Chromium and Safari.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Selects on the press, the way every browser tab strip does, and then
    /// runs the rest of the gesture itself.
    ///
    /// The loop is what makes one press both select and drag. Selecting a
    /// background tab rebuilds the editor hierarchy and the tab strip
    /// underneath the pointer, and AppKit's per-window routing of the
    /// following drag/up events does not survive that churn — they stop
    /// arriving here, so the press could only ever select and the user had
    /// to press a second time to drag. Dequeuing this gesture's own events
    /// directly means nothing can steal them. Local `NSEvent` monitors are
    /// not called inside a nested tracking loop, which is why Esc is
    /// handled in the loop rather than by the bar's monitor.
    override func mouseDown(with event: NSEvent) {
        dragTrackingStart = event.locationInWindow
        lastDragScreenPoint = screenPoint(of: event)
        isDraggingTab = false
        onSelect?(self)

        // No window means no event queue to track — unit tests drive the
        // mouse methods directly on a bar that was never put in one.
        // Selection can also have removed this tab outright.
        guard superview != nil, window != nil else { return }

        // The app's queue, not this window's: a tear-off makes a new window
        // key half way through the gesture, and the drags and the mouse-up
        // then belong to that one. Asking only this window for its own
        // events would strand the tab the moment it left the strip. The
        // view can also leave the strip while the loop runs — the note goes
        // to another window, its tab view goes with it — so the loop holds
        // itself alive and ends on the mouse-up rather than on the window.
        withExtendedLifetime(self) {
            while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                                             until: .distantFuture,
                                             inMode: .eventTracking,
                                             dequeue: true) {
                switch next.type {
                case .leftMouseDragged:
                    mouseDragged(with: next)
                case .leftMouseUp:
                    mouseUp(with: next)
                    return
                case .keyDown:
                    // Esc abandons a drag in progress, but the button is still
                    // down: keep dequeuing until it comes up. Every other key is
                    // swallowed for the duration of the gesture.
                    guard next.keyCode == 53 else { break }
                    let wasDragging = isDraggingTab
                    isDraggingTab = false
                    dragTrackingStart = nil
                    if wasDragging { onDragEnd?(self, false, lastDragScreenPoint) }
                default:
                    break
                }
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragTrackingStart else { return }
        let location = event.locationInWindow
        let screen = screenPoint(of: event)
        lastDragScreenPoint = screen
        if !isDraggingTab {
            // Count the user's actual pointer travel. Looking only at x made
            // a natural, slightly diagonal gesture take longer to engage.
            guard hypot(location.x - start.x, location.y - start.y) >= Self.dragThreshold else {
                return
            }
            isDraggingTab = true
            // The grab point, not the current location: the tab must not
            // jump forward by the threshold the moment it lifts off.
            if let grab = superview?.convert(start, from: nil) {
                onDragStart?(self, grab)
            }
        }
        onDragMove?(self, barPoint(of: event, onScreen: screen), screen)
    }

    override func mouseUp(with event: NSEvent) {
        dragTrackingStart = nil
        guard isDraggingTab else { return }
        isDraggingTab = false
        onDragEnd?(self, true, screenPoint(of: event))
    }

    /// The pointer on screen. An event carries its location in *its own*
    /// window, which stops being this one the moment a tab is torn off, so
    /// the event's window is the only sound thing to convert through.
    private func screenPoint(of event: NSEvent) -> NSPoint {
        let source = event.window ?? window
        return source?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    /// The same pointer in the strip's coordinates. An event from another
    /// window comes back through the screen; one from this window is
    /// converted directly, which is what every drag before a tear-off is.
    private func barPoint(of event: NSEvent, onScreen screen: NSPoint) -> NSPoint? {
        guard let superview else { return nil }
        guard let window, event.window !== window else {
            return superview.convert(event.locationInWindow, from: nil)
        }
        return superview.convert(window.convertPoint(fromScreen: screen), from: nil)
    }

    /// Right-click and ctrl-click: bookmark this tab, or close it. Returning
    /// a menu from here is all AppKit needs — it raises it itself, and the
    /// press never reaches `mouseDown`'s tracking loop.
    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?(self)
    }

    /// Middle-click closes, the way it does in a browser.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onClose?(self)
    }

    @objc private func closeClicked() {
        onClose?(self)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Only the selected fill is drawn here; it has nothing to animate.
        // The hover wash is `hoverFillView`, under everything else, so it can
        // fade in with the slot.
        if isSelected {
            // The ground first, so the pill is solid: a tab dragged over its
            // neighbours covers their titles rather than letting them show
            // through its wash. The ground is the editor's, the one the strip
            // itself sits on, so at rest the pill reads exactly as before.
            let pill = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
            NSColor.textBackgroundColor.setFill()
            pill.fill()
            StripWash.selected(for: self).setFill()
            pill.fill()
        }

        // Sits behind the ✕, which is a subview and so draws on top of this.
        if isHoveringClose, !isCompact {
            let disc = isPressingClose
                ? StripWash.closeDiscPressed(for: self)
                : StripWash.closeDisc(for: self)
            disc.setFill()
            NSBezierPath(ovalIn: slotRect).fill()
        }

        drawTitle()

        // With the slot gone, the only place left to say "unsaved" is the
        // corner of the icon.
        if isCompact, isDirty {
            let diameter = Self.compactDotDiameter
            // Where there is no icon, the dot leads the tab on its own.
            let dot = TabStripLayout.showsTabIcons
                ? NSRect(x: iconRect.maxX - diameter + 1, y: iconRect.minY - 1,
                         width: diameter, height: diameter)
                : NSRect(x: Self.horizontalPadding / 2 - diameter / 2,
                         y: (bounds.height - diameter) / 2,
                         width: diameter, height: diameter)
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
            // The file has moved under the edits: the same ring the roomy
            // slot draws, round the smaller dot.
            if hasExternalChange {
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -2, dy: -2))
                ring.lineWidth = 1
                NSColor.tertiaryLabelColor.setStroke()
                ring.stroke()
            }
        }
    }

    /// Draws the title clipped, not ellipsized: a tab strip that shrinks
    /// wants a title that keeps as many letters as it can and simply runs
    /// out, so the last few points are faded away instead. Erasing through a
    /// gradient inside a transparency layer takes the text's own alpha with
    /// it, which is what makes the fade work whatever sits behind the tab.
    private func drawTitle() {
        let available = titleRect
        guard available.width >= Self.minimumTitleWidth else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: isSelected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        let size = (title as NSString).size(withAttributes: attributes)
        let rect = NSRect(
            x: available.minX,
            y: (bounds.height - size.height) / 2,
            width: available.width,
            height: size.height
        )

        guard size.width > available.width, let context = NSGraphicsContext.current?.cgContext else {
            (title as NSString).draw(in: rect, withAttributes: attributes)
            return
        }

        context.saveGState()
        context.clip(to: rect)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        (title as NSString).draw(in: rect, withAttributes: attributes)
        context.setBlendMode(.destinationOut)
        NSGradient(
            starting: NSColor(white: 0, alpha: 0),
            ending: NSColor(white: 0, alpha: 1)
        )?.draw(
            in: NSRect(
                x: rect.maxX - Self.titleFadeWidth,
                y: rect.minY,
                width: Self.titleFadeWidth,
                height: rect.height
            ),
            angle: 0
        )
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

/// The file icon. Hit-testing goes through to the tab: an `NSImageView` is
/// not opaque, and in the title-bar region a press on any non-opaque view
/// that does not refuse `mouseDownCanMoveWindow` drags the window instead.
private final class TabIconView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The unsaved-changes dot. Transparent to the mouse, so clicking it selects
/// the tab rather than doing nothing.
private final class DirtyDotView: NSView {
    /// The file behind this tab has changed on disk under the unsaved edits:
    /// a hairline ring round the dot. Distinct from the dot on its own at a
    /// glance, and quiet enough to belong in a strip that has no colour in it
    /// — the dot still says "unsaved", and the ring says the file has moved
    /// as well.
    var showsRing = false {
        didSet {
            guard showsRing != oldValue else { return }
            needsDisplay = true
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let diameter: CGFloat = 6
        let rect = NSRect(
            x: (bounds.width - diameter) / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        )
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(ovalIn: rect).fill()

        guard showsRing else { return }
        let ringDiameter: CGFloat = 12
        let ring = NSBezierPath(ovalIn: NSRect(
            x: (bounds.width - ringDiameter) / 2,
            y: (bounds.height - ringDiameter) / 2,
            width: ringDiameter,
            height: ringDiameter
        ).insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        NSColor.tertiaryLabelColor.setStroke()
        ring.stroke()
    }
}

/// Reports pointer enter/exit so the tab can draw the circle behind the ✕,
/// and the press as well: the disc goes a step darker while the ✕ is held, so
/// the click has an answer before the tab goes.
private final class TabCloseButton: NSButton {
    /// Same reason as `NewTabButton`: a press on the ✕ must never move the window.
    override var mouseDownCanMoveWindow: Bool { false }
    var onHoverChange: ((Bool) -> Void)?
    var onHighlightChange: ((Bool) -> Void)?

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        onHighlightChange?(flag)
    }

    private var hoverArea: NSTrackingArea?

    /// While faded out the ✕ must not swallow clicks — otherwise clicking the
    /// slot of a tab in a background window would close it instead of
    /// selecting it, since hover tracking only runs in the key window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue > 0 ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }
}
